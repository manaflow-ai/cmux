#if os(iOS)
import CmuxMobileDiff
import SwiftUI
import UIKit

/// What a native row does with taps and long presses: the same intents and menus as the
/// SwiftUI row it stands in for.
@MainActor
enum ChatNativeRowActions {
    static func configure(_ actions: inout ChatNativeActions, row: ChatRow, context: ChatRowContext) {
        let store = context.store
        let surface = context.surface
        let disclosures = surface.disclosures
        switch row.kind {
        case .prompt(let text, _, let at, let isLast):
            let turnID = row.turnID
            actions.menu = { _ in
                var items: [UIMenuElement] = [
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = text },
                    UIAction(title: "Select Text", image: UIImage(systemName: "selection.pin.in.out")) { _ in ChatSelectText.present(text) },
                ]
                if isLast {
                    items.append(UIAction(title: "Edit and Resend", image: UIImage(systemName: "pencil")) { _ in context.editAndResend(turnID: turnID) })
                } else if context.canEditEarlier(turnID: turnID) {
                    // An earlier prompt: edited in its own sheet, sent in a copy of the chat forked before it.
                    items.append(UIAction(title: "Edit and Resend", image: UIImage(systemName: "pencil")) { _ in context.editEarlier(turnID: turnID) })
                }
                items.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in ChatShare.present(text) })
                items += ChatPolishMenus.promptItems(turnID: turnID, text: text, store: store)
                return UIMenu(children: [UIMenu(title: AgentTurn.menuTimestamp(at), options: .displayInline, children: items)])
            }
        case .incoming(let incoming, let at):
            let turnID = row.turnID
            actions.menu = { _ in
                var items: [UIMenuElement] = [
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = incoming.text },
                    UIAction(title: "Copy as Sent", image: UIImage(systemName: "envelope")) { _ in UIPasteboard.general.string = incoming.raw },
                ]
                if let id = incoming.messageID {
                    items.append(UIAction(title: "Copy Message ID \(id)", image: UIImage(systemName: "number")) { _ in UIPasteboard.general.string = id })
                }
                items += ChatPolishMenus.promptItems(turnID: turnID, text: incoming.text, store: store)
                return UIMenu(children: [UIMenu(title: AgentTurn.menuTimestamp(at), options: .displayInline, children: items)])
            }
        case .tool(let call):
            let openFile = context.openFile
            actions.menu = { _ in
                var items: [UIMenuElement] = []
                if openFile.isAvailable {
                    for location in call.locations.prefix(5) {
                        items.append(UIAction(title: "Open \((location.path as NSString).lastPathComponent)",
                                              image: UIImage(systemName: "doc.text.magnifyingglass")) { _ in openFile(location.path, line: location.line) })
                    }
                }
                if let path = call.locations.first?.path {
                    items.append(UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = path })
                }
                return items.isEmpty ? nil : UIMenu(children: items)
            }
        case .edit(let call, let files):
            let turnID = row.turnID
            let openDiff = context.openDiff
            let openFile = context.openFile
            actions.hit = { hit in
                switch hit {
                case .openDiff(let file):
                    Task { @MainActor in openDiff(await context.changeSet(turnID: turnID, fallbackID: call.id), file: file) }
                case .toggle(let key): toggleDisclosure(context.foldHold, key: key, in: disclosures) { disclosures.set(key, true) }
                default: break
                }
            }
            actions.menu = { pressed in
                // The card pressed (a snippet shows one card per file it edited).
                guard let file = files?.first(where: { $0.file.id == pressed })?.file ?? files?.first?.file else { return nil }
                var items: [UIMenuElement] = [
                    UIAction(title: "Open Diff", image: UIImage(systemName: "arrow.up.right.square")) { _ in
                        Task { @MainActor in openDiff(await context.changeSet(turnID: turnID, fallbackID: call.id), file: file.id) }
                    },
                ]
                if openFile.isAvailable, file.status != .deleted {
                    items.append(UIAction(title: "Open File", image: UIImage(systemName: "doc.text.magnifyingglass")) { _ in openFile(file.path) })
                }
                items.append(UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = file.path })
                return UIMenu(children: items)
            }
            return
        case .editedFiles(let changes):
            let openDiff = context.openDiff
            actions.viewed = viewed(changes)
            actions.menu = { _ in nil }
            actions.hit = { hit in
                if case .openDiff(let file) = hit { openDiff(changes, file: file) }
            }
            return
        case .actions(let turn, _):
            actions.menu = { _ in nil }
            actions.moreMenu = {
                var items: [UIMenuElement] = [
                    UIAction(title: "Copy as Markdown", image: UIImage(systemName: "text.document")) { _ in UIPasteboard.general.string = turn.answerMarkdown },
                    UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise")) { _ in store.retry(turn) },
                ]
                // Retry with another model (`RetryModelChoice`), read when the menu opens.
                if !store.retryModels.isEmpty {
                    let models = store.retryModels.map { model in
                        UIAction(title: model.name, image: model.id == store.currentModelID ? UIImage(systemName: "checkmark") : nil) { _ in
                            store.retry(turn, model: model.id)
                        }
                    }
                    items.append(UIMenu(title: RetryModelChoice.title, image: UIImage(systemName: "arrow.triangle.2.circlepath"), children: models))
                }
                items += ChatPolishMenus.answerItems(turn: turn, store: store)
                return UIMenu(children: [UIMenu(title: AgentTurn.menuTimestamp(turn.endedAt ?? turn.promptAt), options: .displayInline, children: items)])
            }
            actions.hit = { hit in
                switch hit {
                case .copyAnswer: UIPasteboard.general.string = turn.answerMarkdown
                case .shareAnswer: ChatShare.present(turn.answerMarkdown)
                case .retry: store.retry(turn)
                default: break
                }
            }
            return
        case .thought, .toolGroup:
            actions.menu = { _ in nil }
        default:
            break
        }
        // A native line opens its disclosure through the transcript's hold and spring, as its
        // SwiftUI row's button does (`toggleDisclosure`): the tapped line stays where it is drawn,
        // and a chat following its newest row does not re-pin to it while the body opens.
        actions.hit = { hit in
            if case .toggle(let key) = hit { toggleDisclosure(context.foldHold, key: key, in: disclosures) { disclosures.set(key, true) } }
        }
    }

    /// The card's files that are marked viewed, by index.
    static func viewed(_ changes: DiffChangeSet) -> Set<Int> {
        Set(changes.files.indices.filter { DiffViewedStore.shared.isViewed(key: viewedKey(changes.files[$0], in: changes.id)) })
    }

    /// `DiffViewedStore.key(for:)`: the file's content hash is computed once per content
    /// (`DiffFile.contentHash`), so the key follows every change and needs no cache here.
    static func viewedKey(_ file: DiffFile, in changeSetID: String) -> String {
        DiffViewedStore.key(for: file)
    }
}

/// The chat polish rows of the prompt and answer menus: Bookmark (a prompt), Pin (an
/// answer) and Read Aloud, read when the menu opens.
@MainActor
enum ChatPolishMenus {
    static func promptItems(turnID: String, text: String, store: AgentChatStore) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if let turn = store.turns.first(where: { $0.id == turnID }), store.canBookmark(turn) {
            let marked = store.isBookmarked(turn)
            items.append(UIAction(title: marked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark"),
                                  image: UIImage(systemName: marked ? "bookmark.slash" : "bookmark")) { _ in store.toggleBookmark(turn) })
        }
        items.append(readAloud(ChatReadAloud.id(chat: store.summary.id, turn: turnID, prompt: true), markdown: text))
        return items
    }

    static func answerItems(turn: AgentTurn, store: AgentChatStore) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if store.canPin(turn) {
            let pinned = store.isPinned(turn)
            items.append(UIAction(title: pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                                  image: UIImage(systemName: pinned ? "pin.slash" : "pin")) { _ in store.togglePin(turn) })
        }
        if !turn.answerMarkdown.isEmpty {
            items.append(readAloud(ChatReadAloud.id(chat: store.summary.id, turn: turn.id, prompt: false), markdown: turn.answerMarkdown))
        }
        return items
    }

    private static func readAloud(_ id: String, markdown: String) -> UIAction {
        let reading = ChatReadAloud.shared.isReading(id)
        return UIAction(title: reading ? String(localized: "Stop Reading") : String(localized: "Read Aloud"),
                        image: UIImage(systemName: reading ? "stop.circle" : "speaker.wave.2")) { _ in
            ChatReadAloud.shared.toggle(id, markdown: markdown)
        }
    }
}

/// The prompt's "Select Text" sheet: the whole text, selectable, at medium and large detents.
@MainActor
enum ChatSelectText {
    static func present(_ text: String) {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top else { return }
        let textView = UITextView()
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isEditable = false
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        let controller = UIViewController()
        controller.view = textView
        controller.title = "Select text"
        let navigation = UINavigationController(rootViewController: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak navigation] _ in
            navigation?.dismiss(animated: true)
        })
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        top.present(navigation, animated: true)
    }
}
#endif
