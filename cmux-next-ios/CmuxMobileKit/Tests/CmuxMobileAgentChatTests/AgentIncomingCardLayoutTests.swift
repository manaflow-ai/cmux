#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// TestFlight crash 2026-11-09 (INTERNAL 20261110000821, `ChatRowCell` sizing, "Thread stack size
/// exceeded due to excessive recursion"): the incoming card's header called a private `tag(_:)`
/// helper that resolved to SwiftUI's `View.tag(_:)` on the card itself, so the card drew itself
/// inside its own header without end. Laying the card out must finish, in each header form.
@MainActor @Suite struct AgentIncomingCardLayoutTests {
    static func card(_ incoming: AgentIncoming) -> some View {
        AgentIncomingCard(incoming: incoming, at: Date(timeIntervalSince1970: 0))
    }

    static func height(_ view: some View) -> CGFloat {
        let host = UIHostingController(rootView: view)
        let size = host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))
        host.view.frame = CGRect(origin: .zero, size: CGSize(width: 390, height: size.height))
        host.view.layoutIfNeeded()
        return size.height
    }

    @Test func oneMessageCardLaysOut() {
        let incoming = AgentIncoming(messages: [.init(sender: "a12", text: "Done: landed the fix.")], raw: "Done")
        let height = Self.height(Self.card(incoming))
        #expect(height > 20 && height < 400, "one-line card: \(height)")
    }

    @Test func unverifiedEditedCardLaysOut() {
        let incoming = AgentIncoming(messages: [.init(sender: "", text: "hello")], raw: "hello", unverified: true, edited: true)
        let height = Self.height(Self.card(incoming))
        #expect(height > 20 && height < 400, "unverified, edited card: \(height)")
    }

    @Test func stackedCardLaysOut() {
        let incoming = AgentIncoming(messages: [.init(sender: "a1", text: "one"), .init(sender: "a2", text: "two")], raw: "one two")
        let height = Self.height(Self.card(incoming))
        #expect(height > 40 && height < 600, "two-message card: \(height)")
    }
}
#endif
