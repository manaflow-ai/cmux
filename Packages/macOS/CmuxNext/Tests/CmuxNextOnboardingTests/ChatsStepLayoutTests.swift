import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// nxdog66-v1: with many chats the chats step clipped its title ("Pick up
/// your chats" cut at the bottom) and lost the key hint, and a chat whose
/// folder is an app's private UUID folder showed the raw UUID while its
/// title shrank to "Re...".
@MainActor
@Suite struct ChatsStepLayoutTests {
    func chats(_ count: Int, folder: String = "/work/app") -> [AgentChat] {
        (0..<count).map { index in
            AgentChat(sessionID: "s\(index)", app: .claudeCode, folder: URL(fileURLWithPath: folder),
                      title: "Reply with only the word pong, number \(index)", prompts: 1, lastActive: Date())
        }
    }

    func labels(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { sub -> [NSTextField] in ((sub as? NSTextField).map { [$0] } ?? []) + labels(in: sub) }
    }

    @Test func aLongListNeverClipsTheTitleOrTheKeyHint() async {
        let services = MockOnboardingServices()
        services.firstTaskView = NSView()
        services.agentChats = chats(30)
        let model = OnboardingModel(services: services, start: .chats)
        model.stepDidAppear()
        for _ in 0..<200 where !model.chats.scanned { await Task.yield() }
        let content = StandardChats.makeContent(OnboardingStepContext(model: model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingMetrics.windowSize), styleMask: [.titled], backing: .buffered, defer: true)
        let surface = OnboardingSurfaceView(surface: StandardChats.surface, content: content)
        surface.frame = NSRect(origin: .zero, size: OnboardingMetrics.windowSize)
        window.contentView = surface
        for _ in 0..<20 { await Task.yield(); surface.layoutSubtreeIfNeeded() }
        let all = labels(in: content)
        let title = all.first { $0.stringValue == OnboardingStrings.chatsTitle }
        let hint = all.first { $0.stringValue == OnboardingStrings.chatsKeys }
        #expect(title != nil && hint != nil)
        for label in [title, hint].compactMap({ $0 }) {
            #expect(label.frame.height + 0.5 >= label.intrinsicContentSize.height, "\(label.stringValue) clipped: \(label.frame.height) < \(label.intrinsicContentSize.height)")
        }
    }

    @Test func aUUIDFolderIsNotShownAsTheProject() {
        let chat = chats(1, folder: "/Users/me/Library/Application Support/cmux/agent-home/d4eb9cd6-9db9-4b73-adae-b0450626672d")[0]
        let detail = ChatRow.detail(chat, now: Date())
        #expect(!detail.contains("d4eb9cd6"), "\(detail)")
        #expect(detail.hasPrefix(AgentApp.claudeCode.displayName))
        #expect(ChatRow.detail(chats(1)[0], now: Date()).hasPrefix("app · "))
    }

    @Test func theTitleKeepsItsShareBesideALongDetail() {
        let chat = chats(1, folder: "/work/" + String(repeating: "very-long-project-name-", count: 6))[0]
        let row = ChatRow(chat: chat, now: Date()) {}
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 26))
        host.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: host.leadingAnchor), row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                                     row.topAnchor.constraint(equalTo: host.topAnchor)])
        host.layoutSubtreeIfNeeded()
        let name = labels(in: row).first { $0.stringValue == chat.title }
        #expect((name?.frame.width ?? 0) >= 560 * 0.4 - 30, "title width \(name?.frame.width ?? 0)")
    }
}
