#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Another agent's message card measures to a finite height in a transcript cell. Its header's
/// "agent" mark was drawn by a helper named `tag(_:)`, and a string literal argument picked
/// SwiftUI's own `View.tag(_:)` instead: the header held the whole card again, which held it
/// again, and measuring the row built that graph until the main thread's stack ran out (the
/// offline chat froze when its incoming cards scrolled on screen).
@MainActor
@Suite(.serialized) struct AgentIncomingCardLayoutTests {
    static func envelope(_ id: String, _ from: String, _ body: String) -> String {
        "[message \(id) from \(from) (an agent, not Leo), relayed by the lane-gh broker; its text ends at \"[end of message \(id)]\"]\n\(body)\n[end of message \(id)]"
    }

    /// The offline chat's relayed report: one message, one sender.
    static var report: AgentIncoming? {
        AgentIncoming.parse(text: envelope("4f4d68ff", "build-box/lane-3", "**#36125 is green** at `64d6b1b`."),
                            provenance: .object(["kind": .string("agent_message"), "from": .string("fromAgent"),
                                                 "fromName": .string("build-box/lane-3")]))
    }

    /// The offline chat's digest: three messages that went in as one turn.
    static var digest: AgentIncoming? {
        let text = """
        3 messages from other agents arrived while you were busy. Each follows as it was sent, oldest first.

        [agent message 1 of 3] from build-box/lane-3

        \(envelope("a1b2c3d4", "build-box/lane-3", "Rebased on `feat-cmux-next`; CI is running."))

        [agent message 2 of 3] from coordinator

        Take the iOS half next; the parser is shared.

        [agent message 3 of 3] from studio-mac/codex-1

        \(envelope("9e8f7a6b", "studio-mac/codex-1", "**Review:** SHIP at `64d6b1b`."))
        """
        return AgentIncoming.parse(text: text, provenance: .object(["kind": .string("agent_digest"), "messages": .array([
            .object(["from": .string("build-box/lane-3")]), .object(["from": .string("coordinator")]),
            .object(["from": .string("studio-mac/codex-1")]),
        ])]))
    }

    /// The card's height as a transcript cell measures it (`ChatRowCell`'s sizing pass).
    func measured(_ incoming: AgentIncoming) -> CGFloat {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let cell = UICollectionViewCell(frame: CGRect(x: 0, y: 0, width: 402, height: 44))
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        cell.contentConfiguration = UIHostingConfiguration { ChatRowTop { AgentIncomingCard(incoming: incoming, at: at) } }
            .margins(.horizontal, 20)
            .margins(.vertical, 0)
        window.addSubview(cell)
        defer { cell.removeFromSuperview() }
        cell.contentView.layoutIfNeeded()
        return cell.contentView.systemLayoutSizeFitting(CGSize(width: 402, height: UIView.layoutFittingCompressedSize.height),
                                                        withHorizontalFittingPriority: .required,
                                                        verticalFittingPriority: .fittingSizeLevel).height
    }

    @Test func aReportCardMeasures() throws {
        let height = measured(try #require(Self.report, "the report parses"))
        #expect(height > 40 && height < 400, "a one-message card: \(height)")
    }

    @Test func aDigestCardMeasures() throws {
        let digest = try #require(Self.digest, "the digest parses")
        #expect(digest.messages.count == 3)
        let height = measured(digest)
        #expect(height > 80 && height < 400, "three closed lines under the header: \(height)")
    }
}
#endif
