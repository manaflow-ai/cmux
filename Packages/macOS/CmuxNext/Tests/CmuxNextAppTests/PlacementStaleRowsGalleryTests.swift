import AppKit
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextControl
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import CmuxNextLayout
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

nonisolated struct PlacementGalleryCaptured: Decodable, Sendable {
    nonisolated struct Write: Decodable, Sendable {
        let workspace_key: String
        let index: Int
    }
    let order: [String]
    let writes: [Write]
    let attempts: Int
}

/// Native gallery fixture, not a live-daemon recording. The actual production
/// pending-placement path sends its commands to a scripted daemon; its writes
/// are mirrored back and the real AppKit sidebar is saved without image edits.
/// Both refs pass: expected order is metadata, while behavioral red/green is
/// covered independently. Artifact: Packages/macOS/CmuxNext/placement-stale-rows-gallery.tar.
@MainActor @Suite(.closesItsWindows, .serialized)
struct PlacementStaleRowsGalleryTests {
    private nonisolated struct Seed: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "gallery-seed"
    }
    private nonisolated struct WaitForWrite: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "gallery-wait-for-write"
    }
    private nonisolated struct ReadCaptured: DaemonRequest {
        typealias Response = PlacementGalleryCaptured
        static let command = "gallery-report"
    }

    /// Only removes/inserts the workspace at the index production code sent.
    /// It has no expected-order branch and renders no pixels.
    static let daemonScript = #"""
    import json, sys
    mixed = sys.argv[1] == '1'
    mode = sys.argv[2] if len(sys.argv) > 2 else ''
    attempts = 0
    keys, order, writes, waiting = ['k1'], ['k1'], [], []
    names = {'k1': 'Placement first', 'k2': 'Placement second', 'k3': 'Placement third', 'k4': 'Placement fourth'}
    def answer(id, data):
        print(json.dumps({'id': id, 'ok': True, 'data': data}), flush=True)
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        request = json.loads(line)
        cmd, data = request.get('cmd'), {}
        if cmd == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'session': 's-local', 'registry_id': 's-local',
                    'generation': 'gallery', 'capabilities': ['profiles-v1'] + (['personal-mixed-order-v1'] if mixed else [])}
        elif cmd == 'list-workspaces':
            data = {'registry_id': 's-local', 'workspaces': [
                {'id': i + 1, 'key': key, 'name': names[key], 'screens': []} for i, key in enumerate(keys)]}
        elif cmd == 'list-personal':
            data = {'personal_revision': len(writes), 'sessions': [{'session_id': 's-local'}], 'workspaces': [
                {'session_id': 's-local', 'workspace_key': key, 'index': i} for i, key in enumerate(order)]}
        elif cmd == 'gallery-seed':
            keys, order, writes = ['k1', 'k2', 'k3'], ['k3', 'k1', 'k2'], []
        elif cmd == 'gallery-seed-burst':
            keys, order, writes = ['k1', 'k2', 'k3', 'k4'], ['k4', 'k3', 'k2', 'k1'], []
        elif cmd == 'gallery-wait-for-write' and not writes:
            waiting.append(request['id'])
            continue
        elif cmd == 'set-personal-workspace':
            attempts += 1
            if mode == 'disconnect':
                sys.exit(0)
            if mode == 'fail':
                print(json.dumps({'id': request['id'], 'ok': False, 'error': 'placement refused'}), flush=True)
                continue
            key, index = request['workspace_key'], request['index']
            order.remove(key)
            order.insert(min(index, len(order)), key)
            writes.append({'workspace_key': key, 'index': index})
            print(json.dumps({'event': 'personal-changed'}), flush=True)
            for pending in waiting:
                answer(pending, {})
            waiting.clear()
        elif cmd == 'gallery-report':
            data = {'order': order, 'writes': writes, 'attempts': attempts}
        answer(request['id'], data)
    """#

    static func waitForInitialSnapshot(_ services: AppServices) async throws {
        try await ControlDeadline.shared.run(method: "gallery initial snapshot", deadline: .now + .seconds(10)) { @MainActor in
            for await ready in ObservationStream({
                services.daemon.connection != nil && services.daemon.store.isLoaded
                    && services.daemon.store.workspaces.map(\.id) == ["k1"]
            }) where ready { return }
            throw CancellationError()
        }
    }

    private static func render(mixed: Bool, dark: Bool, out: URL) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let bridge = DaemonBridge.fakePython(["-c", daemonScript, mixed ? "1" : "0"])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-placement-gallery-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            let identity = try await connection.start()
            services.daemon.start(first: { .success((connection, identity)) }, makeConnection: { connection })
            defer { services.daemon.shutdownConnection() }
            try await waitForInitialSnapshot(services)
            services.windows.ordersWindowsIn = false
            let controller = try #require(services.windows.openWindow(workspaces: ["k1"],
                frame: CGRect(x: 100, y: 100, width: 900, height: 600)))
            defer {
                controller.teardown()
                controller.window?.close()
            }
            let sidebar = controller.sidebar
            sidebar.restore(width: 300, hidden: false)
            sidebar.sameTurn.syncNow(rows: true)
            try #require(sidebar.model.sections.flatMap(\.workspaces).map(\.id.rawValue) == ["k1"])
            let savedSections = sidebar.model.sections
            _ = try await connection.request(Seed())
            let snapshot = try await connection.snapshot()
            let scope = DaemonCommandScope()
            defer { scope.close() }
            // One main-actor turn: newer store/membership, saved rendered rows,
            // then production placement. No helper added by the fix is referenced.
            services.daemon.store.apply(snapshot: snapshot.tree)
            services.windows.registry.apply { $0.move(["k1", "k2", "k3"], to: controller.state.id); return WindowRegistry.Changes() }
            sidebar.rows.show(savedSections)
            let stale = sidebar.model.sections.flatMap(\.workspaces).map(\.id.rawValue)
            try #require(stale == ["k1"])
            DaemonCommandScope.$current.withValue(scope) {
                NewWorkspacePlacements.expect("k3", in: controller.state.id, slot: .bottom(anchor: nil),
                                              byDefault: nil, windows: services.windows)
            }
            // The transport signals the first actual write before we await the
            // encompassing production command ticket, which covers every step.
            try await ControlDeadline.shared.run(method: "gallery placement write", deadline: .now + .seconds(10)) {
                _ = try await connection.request(WaitForWrite())
                await scope.waitUntilIdle()
            }
            try #require(scope.ticketCount > 0 && scope.isIdle && scope.failures.isEmpty)
            let captured = try await connection.request(ReadCaptured())
            try #require(!captured.writes.isEmpty)
            let written = try await connection.snapshot()
            services.daemon.store.apply(snapshot: written.tree)
            sidebar.sameTurn.syncNow(rows: true)
            let actual = sidebar.model.sections.flatMap(\.workspaces).map(\.id.rawValue)
            try #require(actual == captured.order, "native rows must reflect actual emitted daemon writes")

            let window = try #require(controller.window)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let theme = dark ? "Soft Blue" : "Soft Blue Light"
            let input = try AANestedGroupsGalleryTests.input(theme)
            _ = ThemeScope.app.store.apply(input)
            controller.themeScope.setOverride(ThemeSpec(theme), input: input, animated: false)
            window.orderFrontRegardless()
            let root = try #require(window.contentView)
            root.layoutSubtreeIfNeeded()
            sidebar.container.sidebarView.renderNow()
            for view in AANestedGroupsGalleryTests.all(root) {
                view.layoutSubtreeIfNeeded()
                view.layer?.removeAllAnimations()
                view.needsDisplay = true
                view.displayIfNeeded()
            }
            CATransaction.flush()
            let surface = sidebar.container
            try #require(surface.bounds.width > 0 && surface.bounds.height > 0)
            let rep = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            surface.cacheDisplay(in: surface.bounds, to: rep)
            let image = try #require(rep.cgImage)
            let name = "\(mixed ? "mixed" : "plain")-\(dark ? "dark" : "light")"
            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: name + ".png"))
            let rows = sidebar.container.sidebarView.debugRows().rows
            let painted = rows.filter { $0.inList && !$0.suppressed && ($0.viewAlpha ?? 0) > 0 }
                .sorted { $0.windowFrame.minY < $1.windowFrame.minY }.compactMap(\.title)
            try #require(painted.count == 3, "the PNG must contain three real native workspace rows")
            let titles = Dictionary(uniqueKeysWithValues: services.daemon.store.workspaces.map { ($0.id, $0.name) })
            try #require(painted == actual.compactMap { titles[$0] }, "painted rows must match the emitted daemon order")
            let receipt: [String: Any] = [
                "kind": "native AppKit gallery fixture with scripted daemon", "mixed_order": mixed,
                "stale_rendered": stale, "seed_personal_order": ["k3", "k1", "k2"],
                "expected_order": ["k1", "k2", "k3"], "actual_order": actual, "painted_names": painted,
                "matches_expected": actual == ["k1", "k2", "k3"],
                "writes": captured.writes.map { write -> [String: Any] in ["workspace_key": write.workspace_key, "index": write.index] },
                "image": name + ".png", "width": image.width, "height": image.height,
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: out.appending(path: name + ".json"))
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "placement-stale-rows-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for mixed in [false, true] {
            for dark in [true, false] { try await Self.render(mixed: mixed, dark: dark, out: out) }
        }
        // Test-only artifact packaging follows the existing native galleries.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "placement-stale-rows-gallery.tar", "placement-stale-rows-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
