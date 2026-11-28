import AppKit
import Testing
@testable import CmuxNextAgentPane

/// Complete the real snapshot producer after its owner or rendering context changes. A rejected
/// image must enter neither the per-page remembered cover nor the app's shared frame cache.
@MainActor @Suite(.serialized)
struct NewTabCaptureOwnershipTests {
    enum Change: CaseIterable { case none, appearance, resize, move, ownership, generation }
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test(arguments: Change.allCases)
    func captureRevalidatesBeforePublishing(_ change: Change) async throws {
        _ = NSApplication.shared
        let model = AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent))
        let view = try #require(AgentPaneView(model: model, source: .bundled(URL(filePath: "/dev/null"))))
        let size = CGSize(width: 937, height: 631)
        let parking = NSView(frame: NSRect(origin: .zero, size: size))
        let adopted = NSView(frame: parking.frame)
        parking.addSubview(view)
        view.frame = parking.bounds
        view.appearance = NSAppearance(named: .aqua)
        let frames = AgentPaneNewTabFrame.shared
        frames.pageMade(model)
        frames.chatsAnswered(.init(chats: [], nextCursor: nil, ready: true, enabled: true, design: UUID().uuidString),
                             query: .init(text: nil, cursor: nil, limit: 1), to: model)
        let covers = AgentPaneSpareCovers()
        model.markPainted()
        var snapshots = 0
        view.redraw.snapshotOverride = {
            snapshots += 1
            switch change {
            case .none: break
            case .appearance: view.appearance = NSAppearance(named: .darkAqua)
            case .resize: view.setFrameSize(CGSize(width: size.width - 1, height: size.height))
            case .move: adopted.addSubview(view)
            case .ownership: covers.forget(view)
            case .generation: frames.modelChanged(.init(agent: UUID().uuidString), by: model)
            }
            return NSImage(size: size)
        }
        defer { view.redraw.snapshotOverride = nil }
        await withCheckedContinuation { done in
            covers.capture(view, parked: { $0.superview === parking }) { done.resume() }
        }
        #expect(snapshots == 1)
        #expect((frames.image(size: size, appearance: .aqua) != nil) == (change == .none))
        #expect((view.redraw.takeRememberedFrame(size: size, appearance: .aqua) != nil) == (change == .none))
    }
}
