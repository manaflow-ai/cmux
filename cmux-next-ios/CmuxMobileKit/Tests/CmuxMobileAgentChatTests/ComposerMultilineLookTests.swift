#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-16: "the ios thing it turns pale in the composer after 3 lines".
/// A 6-line draft's text looks exactly like a 1-line draft's: the same color and
/// opacity, nothing masking or fading the field, the same card behind it.
@MainActor
@Suite struct ComposerMultilineLookTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    struct Chat {
        let window: UIWindow
        let surface: AgentChatSurface
    }

    private func chat(_ style: UIUserInterfaceStyle) -> Chat {
        let store = AgentChatStore(source: Silent())
        let surface = AgentChatSurface()
        let dock = AnyView(AgentChatBottomStack(store: store, surface: surface, bottomPadding: 0))
        let controller = ChatTranscriptController(placement: .owned, surface: surface, store: store,
                                                  empty: AnyView(EmptyView()), dock: dock, jump: nil)
        controller.isEmpty = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.makeKeyAndVisible()
        drain()
        return Chat(window: window, surface: surface)
    }

    private func drain() {
        for _ in 0 ..< 40 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func field(in view: UIView) -> UITextView? {
        if let text = view as? UITextView, text.accessibilityIdentifier == ChatComposerField.accessibilityIdentifier { return text }
        for subview in view.subviews {
            if let found = field(in: subview) { return found }
        }
        return nil
    }

    private static func draft(_ lines: Int) -> String {
        (1 ... lines).map { "line \($0) of the draft" }.joined(separator: "\n")
    }

    /// Everything that changes how the field's text is drawn, from the text view up to
    /// the window: color, alpha, masks, filters, and the edge effects a scroll view draws.
    struct Look: Equatable, CustomStringConvertible {
        var textColor: String
        var chain: [String]
        var edgeEffects: String
        var description: String { "text \(textColor); edges \(edgeEffects)\n  " + chain.joined(separator: "\n  ") }
    }

    private func look(_ text: UITextView) -> Look {
        let color = (text.textColor ?? .clear).resolvedColor(with: text.traitCollection)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        var chain: [String] = []
        var view: UIView? = text
        while let current = view {
            let layer = current.layer
            chain.append("\(type(of: current)) alpha=\(current.alpha) opacity=\(layer.opacity) hidden=\(current.isHidden) "
                + "mask=\(current.mask != nil || layer.mask != nil) filters=\(layer.filters?.count ?? 0) "
                + "compositing=\(layer.compositingFilter.map { "\($0)" } ?? "-") tint=\(current.tintAdjustmentMode.rawValue)")
            view = current.superview
        }
        let edges = "top hidden=\(text.topEdgeEffect.isHidden) bottom hidden=\(text.bottomEdgeEffect.isHidden) "
            + "top style=\(text.topEdgeEffect.style) bottom style=\(text.bottomEdgeEffect.style)"
        return Look(textColor: String(format: "%.3f %.3f %.3f %.3f", r, g, b, a), chain: chain, edgeEffects: edges)
    }

    /// Every view drawn over the field's text inside the text view (a scroll pocket,
    /// an edge effect): their classes and alphas.
    private func overlays(_ text: UITextView) -> [String] {
        var out: [String] = []
        func walk(_ view: UIView, _ depth: Int) {
            for sub in view.subviews {
                out.append(String(repeating: " ", count: depth) + "\(type(of: sub)) alpha=\(sub.alpha) hidden=\(sub.isHidden) frame=\(sub.frame) mask=\(sub.layer.mask != nil) filters=\(sub.layer.filters?.count ?? 0)")
                walk(sub, depth + 1)
            }
        }
        walk(text, 0)
        return out
    }

    private func png(_ window: UIWindow, _ text: UITextView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CMUX_COMPOSER_LOOK_DIR"] ?? Optional(NSTemporaryDirectory()) else { return }
        let card = text.convert(text.bounds, to: window).insetBy(dx: -24, dy: -24)
        let image = UIGraphicsImageRenderer(bounds: card).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("composer-look-\(name).png")
        try? image.pngData()?.write(to: url)
        print("composer-look png \(url.path)")
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func sixLinesLookLikeOne(_ style: UIUserInterfaceStyle) throws {
        let chat = chat(style)
        defer { chat.window.isHidden = true }
        var looks: [Int: Look] = [:]
        for lines in [1, 2, 3, 4, 6] {
            chat.surface.text = Self.draft(lines)
            drain()
            let text = try #require(field(in: chat.window), "no composer field")
            looks[lines] = look(text)
            print("composer-look \(style.rawValue) lines=\(lines) bounds=\(text.bounds) content=\(text.contentSize) offset=\(text.contentOffset) \(looks[lines]!)")
            for line in overlays(text) { print("composer-look \(style.rawValue) lines=\(lines) overlay \(line)") }
            png(chat.window, text, "\(style == .dark ? "dark" : "light")-\(lines)")
        }
        let one = try #require(looks[1])
        for lines in [3, 6] {
            #expect(looks[lines] == one, "\(lines) lines draw unlike 1 line:\n\(looks[lines].map(\.description) ?? "-")\nvs\n\(one)")
        }
    }
}
#endif
