import AppKit
@testable import CmuxNextApps
import Testing

/// App overlays (`presentation.overlay`): only the person's gesture opens one, the mount carries
/// the user origin the supervisor checks, and a saved manifest adds, resizes or drops the overlay
/// with no relaunch (the list an `apps-changed` brings).
@MainActor @Suite(.serialized) struct AppOverlayTests {
    private final class Transport: AppsTransport {
        var availability: AppsAvailability = .available(epoch: 1)
        var onEvent: ((AppsTransportEvent) -> Void)?
        var revision: UInt64 = 1
        var overlay: AppJSON? = ["title": "Scratch", "width": 420, "height": 280]
        /// Each mount with the origin it was sent with (nil: none).
        var mounted: [(id: String, surface: String?, origin: AppOrigin?)] = []

        var manifest: AppJSON {
            var presentation: [String: AppJSON] = [:]
            if let overlay { presentation["overlay"] = overlay }
            return [
                "manifestVersion": 2, "id": "local/scratch", "name": "Scratch Pad", "version": "1.0.0",
                "implements": ["cmux.pane/1": ["export": "renderPad", "title": "Scratch"]],
                "presentation": .object(presentation),
            ]
        }

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply {
            AppsListReply(revision: revision, apps: [AppRecord(json: ["id": "local/scratch", "installed": true, "manifest": manifest])].compactMap { $0 })
        }
        func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] { [] }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
            mounted.append((mountID, context["surface"]?.stringValue, nil))
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON, origin: AppOrigin) async throws(AppsTransportError) {
            mounted.append((mountID, context["surface"]?.stringValue, origin))
        }
        func unmount(mountID: String) async throws(AppsTransportError) {}
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
            .null
        }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    }

    private static func started() async -> (Transport, AppsClient) {
        let transport = Transport()
        let client = AppsClient(transport: transport)
        client.start()
        for _ in 0..<100 where !client.hasList { await Task.yield() }
        return (transport, client)
    }

    /// Lets the list a `changed` event asked for land.
    private static func settle(_ client: AppsClient) async {
        for _ in 0..<100 {
            await Task.yield()
            await client.tail?.value
        }
    }

    @Test func theManifestOverlayDecodesWithItsSizeAndDefaults() throws {
        let sized = try #require(AppPresentation(json: ["overlay": ["width": 420, "height": 280]])?.overlay)
        #expect(sized.size == CGSize(width: 420, height: 280))
        let plain = try #require(AppPresentation(json: ["overlay": [:]])?.overlay)
        #expect(plain.size == AppPresentation.Overlay.defaultSize)
        #expect(AppPresentation(json: ["tab": true])?.overlay == nil)
    }

    /// Anything but the person's own gesture is refused before a mount is sent; an app with no
    /// overlay is refused for the person too.
    @Test func onlyThePersonsGestureOpensAnOverlay() async throws {
        let (transport, client) = await Self.started()
        let record = try #require(client.app("local/scratch"))
        for origin in [AppOrigin.cli, .mcp, .script, .remote] {
            #expect(AppOverlayPresenter.refusal(record, origin: origin) == .gesture, "\(origin)")
        }
        #expect(AppOverlayPresenter.refusal(record, origin: .user) == nil)
        transport.overlay = nil
        transport.revision = 2
        transport.onEvent?(.changed(revision: 2))
        await Self.settle(client)
        #expect(AppOverlayPresenter.refusal(client.app("local/scratch"), origin: .user) == .undeclared)
        #expect(AppOverlayPresenter.refusal(nil, origin: .user) == .undeclared)
    }

    /// The overlay's mount goes out with the user origin (the supervisor refuses it otherwise);
    /// every other view's mount still carries none.
    @Test func theOverlayMountCarriesTheUserOrigin() async throws {
        let (transport, client) = await Self.started()
        let record = try #require(client.app("local/scratch"))
        let pane = try #require(AppMountSurface.overlay.implementation(of: record, id: nil))
        let overlay = client.mount("local/scratch", implementation: pane, surface: AppMountSurface.overlay.rawValue, origin: .user)
        let tab = client.mount("local/scratch", implementation: pane, surface: AppMountSurface.pane.rawValue)
        await client.tail?.value
        #expect(transport.mounted.map { $0.id } == [overlay.id, tab.id])
        #expect(transport.mounted[0].surface == "overlay" && transport.mounted[0].origin == .user)
        #expect(transport.mounted[1].surface == "pane" && transport.mounted[1].origin == nil)
    }

    /// Hot reload: a saved manifest changes the palette's offer with no relaunch: a new title
    /// renames the row, and dropping the overlay drops it.
    @Test func aSavedManifestChangesTheOfferedOverlay() async throws {
        let (transport, client) = await Self.started()
        let presenter = AppOverlayPresenter(client: client)
        #expect(presenter.offered.map { $0.app } == ["local/scratch"])
        #expect(presenter.offered.first?.title.contains("Scratch") == true)
        transport.overlay = ["title": "Notes", "width": 300, "height": 200]
        transport.revision = 2
        transport.onEvent?(.changed(revision: 2))
        await Self.settle(client)
        #expect(presenter.offered.first?.title.contains("Notes") == true)
        #expect(client.app("local/scratch")?.manifest.presentation?.overlay?.size == CGSize(width: 300, height: 200))
        transport.overlay = nil
        transport.revision = 3
        transport.onEvent?(.changed(revision: 3))
        await Self.settle(client)
        #expect(presenter.offered.isEmpty)
    }

    @Test func theCardKeepsAMarginInsideTheWindow() {
        let overlay = AppPresentation.Overlay(json: ["width": 900, "height": 200])
        let size = AppOverlayPresenter.cardSize(overlay, in: CGSize(width: 600, height: 400), margin: 20)
        #expect(size == CGSize(width: 560, height: 200))
    }
}
