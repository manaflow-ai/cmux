#if os(iOS)
@testable import CmuxAgentGUIUI
import CmuxAgentGUIProjection
import SwiftUI
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @Test func mountedScrollToBottomPillReceivesHits() throws {
        let model = TranscriptDemoModel()
        model.setTallFixtureEnabled(true)
        let container = TranscriptDemoContainerViewController(
            theme: AgentGUITheme(terminalTheme: .monokai)
        )
        container.installComposer(model: model, density: .constant(.comfortable))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        window.makeKeyAndVisible()
        container.apply(input: model.input)
        Self.pumpLiveRunLoop()
        container.view.layoutIfNeeded()
        container.transcript.collectionView.layoutIfNeeded()
        let composerHost = try #require(container.composerHostView)
        let field = try #require(Self.firstSubview(of: UITextField.self, in: composerHost))
        defer {
            field.resignFirstResponder()
            Self.pumpLiveRunLoop(duration: 0.5)
            window.isHidden = true
        }
        let controller = container.transcript
        controller.scrollToBottom(animated: false)
        controller.collectionView.setContentOffset(
            CGPoint(x: 0, y: -controller.collectionView.contentInset.top),
            animated: false
        )
        controller.scrollViewDidScroll(controller.collectionView)

        func expectHit(unreadCount: Int, keyboardVisible: Bool) throws {
            controller.unreadCount = unreadCount == 0 ? 15 : 0
            controller.updatePillVisibility()
            Self.pumpLiveRunLoop(duration: 0.2)
            controller.unreadCount = unreadCount
            controller.updatePillVisibility()
            Self.pumpLiveRunLoop(duration: 0.4)
            container.view.layoutIfNeeded()

            let host = try #require(controller.pillHost?.view)
            #expect(host.isUserInteractionEnabled)
            #expect(host.alpha == 1)
            #expect(host.bounds.width > 0)
            #expect(host.bounds.height > 0)

            let hostFrame = host.convert(host.bounds, to: window).standardized
            let pillBounds = host.bounds.inset(by: host.safeAreaInsets)
            let pillCenter = host.convert(
                CGPoint(x: pillBounds.midX, y: pillBounds.midY),
                to: window
            )
            let pillHit = try #require(window.hitTest(pillCenter, with: nil))
            #expect(
                pillHit === host || pillHit.isDescendant(of: host),
                "Expected pill host descendant for unread=\(unreadCount), keyboard=\(keyboardVisible); got \(Self.viewAncestry(from: pillHit)) for host frame \(hostFrame)"
            )

            let outsidePoint = CGPoint(x: hostFrame.midX, y: hostFrame.minY - 1)
            let outsideHit = try #require(window.hitTest(outsidePoint, with: nil))
            let collectionView = controller.collectionView!
            #expect(outsideHit === collectionView || outsideHit.isDescendant(of: collectionView))
        }

        for unreadCount in [0, 15] {
            try expectHit(unreadCount: unreadCount, keyboardVisible: false)
        }

        #expect(field.becomeFirstResponder())
        Self.pumpLiveRunLoop(duration: 0.7)
        #expect(field.isFirstResponder)
        #expect(controller.keyboardIsDocked)
        for unreadCount in [0, 15] {
            try expectHit(unreadCount: unreadCount, keyboardVisible: true)
        }
    }

    private static func firstSubview<View: UIView>(of type: View.Type, in root: UIView) -> View? {
        if let match = root as? View {
            return match
        }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private static func viewAncestry(from view: UIView) -> String {
        var ancestry: [String] = []
        var current: UIView? = view
        while let candidate = current {
            ancestry.append("\(type(of: candidate)) frame=\(candidate.frame)")
            current = candidate.superview
        }
        return ancestry.joined(separator: " -> ")
    }
}
#endif
