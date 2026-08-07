import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import NativeMuxDemo

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

@Test
func decodesEveryNativeLayoutShape() throws {
    let data = Data(
        #"""
        {
          "machine":{"id":"machine_11111111111111111111111111111111"},
          "session":{"id":"session_22222222222222222222222222222222","name":"demo"},
          "workspaces":[{"id":"ws_33333333333333333333333333333333","name":"agents","index":0,"focused":true}],
          "screens":[{
            "id":"screen_44444444444444444444444444444444",
            "workspace_id":"ws_33333333333333333333333333333333",
            "name":"main","index":0,"focused":true,
            "layout":{
              "version":1,
              "screen_id":"screen_44444444444444444444444444444444",
              "active_pane_id":"pane_55555555555555555555555555555555",
              "zoomed_pane_id":null,
              "root":{"kind":"viewport","base_width":0.5,"columns":[
                {"column_id":"column_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","width":0.5,"root":{
                  "kind":"split","split_id":"split_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                  "direction":"horizontal","ratio":0.6,
                  "first":{"kind":"leaf","pane_id":"pane_55555555555555555555555555555555","tab_ids":["tab_77777777777777777777777777777777"],"active_tab_id":"tab_77777777777777777777777777777777"},
                  "second":{"kind":"stack","pane_ids":["pane_66666666666666666666666666666666"],"expanded_pane_id":"pane_66666666666666666666666666666666"}
                }}
              ]}
            }
          }],
          "panes":[
            {"id":"pane_55555555555555555555555555555555","screen_id":"screen_44444444444444444444444444444444","name":null,"focused":true,"zoomed":false},
            {"id":"pane_66666666666666666666666666666666","screen_id":"screen_44444444444444444444444444444444","name":null,"focused":false,"zoomed":false}
          ],
          "tabs":[{"id":"tab_77777777777777777777777777777777","pane_id":"pane_55555555555555555555555555555555","name":null,"index":0,"focused":true,"content_kind":"terminal","content_id":"term_88888888888888888888888888888888"}],
          "terminals":[{"id":"term_88888888888888888888888888888888","tab_id":"tab_77777777777777777777777777777777","title":"shell","cols":80,"rows":24,"running":true,"lifecycle":"running"}],
          "browsers":[],
          "cursor":{"generation":"g","revision":"8"}
        }
        """#.utf8
    )

    let snapshot = try JSONDecoder().decode(ResourceSnapshot.self, from: data)
    #expect(snapshot.workspaces.first?.name == "agents")
    #expect(snapshot.screens.first?.layout.root.paneIDs.count == 2)
    guard case .viewport(let baseWidth, let columns) = snapshot.screens[0].layout.root else {
        Issue.record("viewport root was not decoded")
        return
    }
    #expect(baseWidth == 0.5)
    #expect(columns.count == 1)
    guard case .split(_, .horizontal, let ratio, _, let second) = columns[0].root else {
        Issue.record("split column was not decoded")
        return
    }
    #expect(ratio == 0.6)
    guard case .stack(let panes, let expanded) = second else {
        Issue.record("stack child was not decoded")
        return
    }
    #expect(panes == [expanded])
}

@Test
func resourceParametersPreserveMixedJSONTypes() throws {
    let encoded = try [
        "direction": JSONValue.string("right"),
        "viewport_width": .number(0.55),
        "columns": .integer(72),
        "enabled": .bool(true),
    ].encodedJSON()
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
    )
    #expect(object["direction"] as? String == "right")
    #expect(object["viewport_width"] as? Double == 0.55)
    #expect(object["columns"] as? Int == 72)
    #expect(object["enabled"] as? Bool == true)
}

@Test
func terminalGeometryIsBoundedAndNonzero() {
    #expect(terminalGeometry(width: 0, height: 0) == TerminalGeometry(cols: 1, rows: 1))
    #expect(terminalGeometry(width: 856, height: 424) == TerminalGeometry(cols: 100, rows: 24))
}

@Test
func terminalHandleFFIQueuePreservesFIFOAndDisconnectDrain() async {
    let executor = SerialFFIExecutor(label: "test.native-terminal.fifo")
    let started = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let order = EventLog()
    let first = Task {
        await executor.run {
            order.append("send")
            started.continuation.yield()
            release.wait()
            return true
        }
    }
    for await _ in started.stream { break }
    #expect(order.snapshot == ["send"])
    let readEnqueued = AsyncStream<Void>.makeStream()
    let read = Task {
        await executor.run({ order.append("read"); return true }, onEnqueued: { readEnqueued.continuation.yield() })
    }
    for await _ in readEnqueued.stream { break }
    let removeEnqueued = AsyncStream<Void>.makeStream()
    let removeCallback = Task {
        await executor.run({ order.append("callback-removal"); return true }, onEnqueued: { removeEnqueued.continuation.yield() })
    }
    for await _ in removeEnqueued.stream { break }
    let disconnectEnqueued = AsyncStream<Void>.makeStream()
    let disconnect = Task {
        await executor.run({ order.append("disconnect"); return true }, onEnqueued: { disconnectEnqueued.continuation.yield() })
    }
    for await _ in disconnectEnqueued.stream { break }
    #expect(order.snapshot == ["send"])
    release.signal()
    _ = await first.value
    _ = await read.value
    _ = await removeCallback.value
    _ = await disconnect.value
    #expect(order.snapshot == ["send", "read", "callback-removal", "disconnect"])
}

@Test
func resizeQueueKeepsOnlyNewestPendingGeometry() {
    var queue = NewestResizeQueue()
    let firstStarts = queue.submit(TerminalGeometry(cols: 80, rows: 24))
    #expect(firstStarts)
    #expect(queue.take() == TerminalGeometry(cols: 80, rows: 24))
    let secondStarts = queue.submit(TerminalGeometry(cols: 100, rows: 30))
    #expect(secondStarts)
    let thirdStarts = queue.submit(TerminalGeometry(cols: 120, rows: 40))
    #expect(!thirdStarts)
    #expect(queue.take() == TerminalGeometry(cols: 120, rows: 40))
    #expect(queue.take() == nil)
}

@Test
func decodesNativeResetSidecarKittyAliasesAndCursors() {
    var payload = Data("CMNR".utf8)
    payload.append(1)
    payload.append(contentsOf: UInt32(3).littleEndianBytes)
    payload.append(contentsOf: UInt16(1).littleEndianBytes)
    for value in [UInt64(10), UInt64(20), UInt64(30), UInt64(40)] { payload.append(contentsOf: value.littleEndianBytes) }
    for value in [UInt32(2), UInt32(3), UInt32(4), UInt32(5), UInt32(6)] { payload.append(contentsOf: value.littleEndianBytes) }
    payload.append(contentsOf: UInt32(41).littleEndianBytes)
    payload.append(contentsOf: UInt32(77).littleEndianBytes)
    payload.append(contentsOf: Data("abc".utf8))
    let metadata = NativeKittyResetMetadata.decode(payload)
    #expect(metadata?.replay == Data("abc".utf8))
    #expect(metadata?.aliases.first?.0 == 41)
    #expect(metadata?.aliases.first?.1 == 77)
    #expect(metadata?.replayNextIDs.0 == 3)
    #expect(metadata?.nextIDs.1 == 6)
}

@Test
func sideBySideLayoutLeavesVisibleSpaceForBothFrontends() {
    let visibleFrame = CGRect(x: 0, y: 25, width: 1728, height: 971)
    let layout = SideBySideWindowLayout.fit(visibleFrame: visibleFrame)

    #expect(layout.nativeFrame.minX == visibleFrame.minX)
    #expect(layout.nativeFrame.minY == visibleFrame.minY)
    #expect(layout.nativeFrame.height == visibleFrame.height)
    #expect(layout.nativeFrame.width > 900)
    #expect(layout.ghosttyPositionX > Int(layout.nativeFrame.maxX))
    #expect(layout.ghosttyPositionY == 0)
    #expect(layout.ghosttyColumns >= 80)
    #expect(layout.ghosttyRows >= 40)
}

@Test
func launcherPreparesGhosttyKitBeforeSwiftBuild() throws {
    let packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let launcher = try String(
        contentsOf: packageDirectory.appendingPathComponent("run-demo.sh"),
        encoding: .utf8
    )
    let ensureRange = try #require(launcher.range(of: "scripts/ensure-ghosttykit.sh"))
    let swiftBuildRange = try #require(launcher.range(of: "swift build"))

    #expect(ensureRange.lowerBound < swiftBuildRange.lowerBound)
}

@Test
func ghosttyLauncherRunsExactCmuxBinaryByName() throws {
    let packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let launcher = packageDirectory.appendingPathComponent("launch-ghostty-client.sh")
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-native-ghostty-launch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let fakeGhostty = temporaryDirectory
        .appendingPathComponent("Ghostty.app/Contents/MacOS/ghostty")
    let fakeCmux = temporaryDirectory.appendingPathComponent("exact-bin/cmux-tui")
    let output = temporaryDirectory.appendingPathComponent("arguments.txt")
    try FileManager.default.createDirectory(
        at: fakeGhostty.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: fakeCmux.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try #"""
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GHOSTTY_MAC_LAUNCH_SOURCE:-}" == "cli" ]]
    while [[ $# -gt 0 && "$1" != "-e" ]]; do shift; done
    [[ "${1:-}" == "-e" ]]
    shift
    [[ "${1:-}" == "cmux-tui" ]]
    command_name="$1"
    shift
    "$command_name" "$@"
    """#.write(to: fakeGhostty, atomically: true, encoding: .utf8)
    try #"""
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\n' "$@" > "${CMUX_GHOSTTY_LAUNCH_TEST_OUTPUT:?}"
    """#.write(to: fakeCmux, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: fakeGhostty.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: fakeCmux.path
    )

    let process = Process()
    process.executableURL = launcher
    process.arguments = [
        temporaryDirectory.appendingPathComponent("Ghostty.app").path,
        fakeCmux.path,
        "--title=launcher test",
        "--",
        "--probe",
        "alpha beta",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["CMUX_GHOSTTY_LAUNCH_TEST_OUTPUT"] = output.path
    process.environment = environment
    let standardError = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()

    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(decoding: errorData, as: UTF8.self)
    #expect(process.terminationStatus == 0, "launcher failed: \(errorText)")
    let arguments = try String(contentsOf: output, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(arguments == ["--probe", "alpha beta"])
}

@Test
func packageLinksFrameworkRequiredByIrohInterfaceDiscovery() throws {
    let packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifest = try String(
        contentsOf: packageDirectory.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )

    #expect(manifest.contains(".linkedFramework(\"CoreWLAN\")"))
}

@Test @MainActor
func appDelegateCreatesAndOwnsInitialWindow() throws {
    let model = FrontendModel(configuration: DemoLaunchConfiguration(
        invitation: "",
        autoConnect: false
    ))
    let delegate = NativeMuxDemoAppDelegate(model: model)
    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )
    let window = try #require(delegate.window)
    defer { window.close() }

    #expect(window.isVisible)
    #expect(window.delegate === delegate)
    #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
}
