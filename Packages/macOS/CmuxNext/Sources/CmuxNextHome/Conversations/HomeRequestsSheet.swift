public import AppKit
public import CmuxHomeCore
import CmuxNextDesign

/// "Message Requests" (plans/cmux-next/home-messaging-invites/DESIGN.md 2.3): invites from
/// people the user has not talked to, each with Accept, Decline and Block. They made no sound
/// and badge nothing; the sender learns nothing from a decline or a block. Accept closes the
/// sheet on the conversation; the others take the request off the sheet.
public final class HomeRequestsSheet: HomeSheetController {
    /// The host answers through the request model; false keeps the request and says it failed.
    public var onAnswer: (ConversationID, HomeRequestAnswer) async -> Bool = { _, _ in false }
    private var requests: [HomeMessageRequest]
    private let list = NSStackView()
    /// Each answer button's request and answer.
    private var choices: [ObjectIdentifier: (ConversationID, HomeRequestAnswer)] = [:]
    // task-owner: the one answer in flight; ends with its reply
    private var answering: Task<Void, Never>?

    public init(requests: [HomeMessageRequest]) {
        self.requests = requests
        super.init(title: HomeConversationStrings.requestsTitle, primary: HomeConversationStrings.requestsDone)
    }

    override func addContent(to stack: NSStackView) {
        let body = ThemedLabel(wrappingLabelWithString: HomeConversationStrings.requestsBody)
        body.font = Typography.caption
        body.ink = .secondary
        body.preferredMaxLayoutWidth = Self.width
        stack.addArrangedSubview(body)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = Metrics.space4
        list.setAccessibilityIdentifier("cmux.home.requests.list")
        stack.addArrangedSubview(list)
        reloadList()
    }

    static var width: CGFloat { 420 - 2 * Metrics.space6 }

    /// Replaces the shown requests (the model listed them again).
    public func update(_ requests: [HomeMessageRequest]) {
        guard requests != self.requests else { return }
        self.requests = requests
        if isViewLoaded { reloadList() }
    }

    private func reloadList() {
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        choices = [:]
        guard !requests.isEmpty else {
            let none = ThemedLabel(labelWithString: HomeConversationStrings.requestsNone)
            none.font = Typography.body
            none.ink = .secondary
            list.addArrangedSubview(none)
            return
        }
        for request in requests { list.addArrangedSubview(row(request)) }
    }

    private func row(_ request: HomeMessageRequest) -> NSView {
        let name = ThemedLabel(labelWithString: request.inviter)
        name.font = Typography.header
        let head = NSStackView(views: [name])
        head.spacing = Metrics.space2
        if request.trusted {
            let tag = ThemedLabel(labelWithString: HomeConversationStrings.requestTrusted)
            tag.font = Typography.caption
            tag.ink = .secondary
            head.addArrangedSubview(tag)
        }
        let column = NSStackView(views: [head])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.space1
        var detail: [String] = []
        if request.isGroup { detail.append(request.title.map(HomeConversationStrings.requestGroup) ?? HomeConversationStrings.requestGroupUntitled) }
        if !request.preview.isEmpty { detail.append(request.preview) }
        for line in detail {
            let label = ThemedLabel(wrappingLabelWithString: line)
            label.font = Typography.body
            label.preferredMaxLayoutWidth = Self.width
            label.maximumNumberOfLines = 3
            column.addArrangedSubview(label)
        }
        let buttons = NSStackView(views: [
            button(HomeConversationStrings.requestAccept, request.conversation, .accept, kind: "accept", isDefault: true),
            button(HomeConversationStrings.requestDecline, request.conversation, .decline, kind: "decline", isDefault: false),
            button(HomeConversationStrings.requestBlock, request.conversation, .block, kind: "block", isDefault: false),
        ])
        buttons.spacing = Metrics.space2
        column.addArrangedSubview(buttons)
        column.setAccessibilityElement(true)
        column.setAccessibilityRole(.group)
        column.setAccessibilityLabel([request.inviter, request.isGroup ? request.title ?? "" : "", request.preview]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        return column
    }

    private func button(_ title: String, _ conversation: ConversationID, _ answer: HomeRequestAnswer, kind: String,
                        isDefault: Bool) -> NSButton {
        let button: ThemedBezelButton = isDefault
            ? ThemedDefaultButton(title: title, target: self, action: #selector(choose(_:)))
            : ThemedBezelButton(title: title, target: self, action: #selector(choose(_:)))
        button.setAccessibilityIdentifier("cmux.home.requests.\(kind).\(conversation.rawValue)")
        choices[ObjectIdentifier(button)] = (conversation, answer)
        return button
    }

    @objc private func choose(_ sender: NSButton) {
        guard answering == nil, let (conversation, answer) = choices[ObjectIdentifier(sender)] else { return }
        let ask = onAnswer
        show(nil)
        answering = Task { [weak self] in
            let done = await ask(conversation, answer)
            guard let self else { return }
            answering = nil
            guard done else {
                show(HomeConversationStrings.requestFailed)
                return
            }
            if answer == .accept {
                close(showing: conversation)
            } else {
                requests.removeAll { $0.conversation == conversation }
                reloadList()
            }
        }
    }

    override func submit() { close(showing: nil) }
}
