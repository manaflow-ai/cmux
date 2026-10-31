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
            actions.menu = {
                var items: [UIMenuElement] = [
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = text },
                    UIAction(title: "Select Text", image: UIImage(systemName: "selection.pin.in.out")) { _ in ChatSelectText.present(text) },
                ]
                if isLast {
                    // Into the composer to edit and send from there (over a draft, the transcript asks first).
                    let turnID = row.turnID
                    items.append(UIAction(title: "Edit and Resend", image: UIImage(systemName: "pencil")) { _ in
                        if let turn = store.turns.last(where: { $0.id == turnID }) { surface.editAndResendOrAsk(turn, store: store) }
                    })
                }
                items.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in ChatShare.present(text) })
                return UIMenu(children: [UIMenu(title: AgentTurn.menuTimestamp(at), options: .displayInline, children: items)])
            }
        case .tool(let call):
            let openFile = context.openFile
            actions.menu = {
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
                case .openDiff(let file): openDiff(context.changeSet(turnID: turnID, fallbackID: call.id), file: file)
                case .toggle(let key): ChatMotion.set { disclosures.set(key, true) }
                default: break
                }
            }
            actions.menu = {
                guard let file = files?.first?.file else { return nil }
                var items: [UIMenuElement] = [
                    UIAction(title: "Open Diff", image: UIImage(systemName: "arrow.up.right.square")) { _ in
                        openDiff(context.changeSet(turnID: turnID, fallbackID: call.id), file: file.id)
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
            actions.menu = { nil }
            actions.hit = { hit in
                if case .openDiff(let file) = hit { openDiff(changes, file: file) }
            }
            return
        case .actions(let turn, _):
            actions.menu = { nil }
            actions.moreMenu = {
                var items: [UIMenuElement] = [
                    UIAction(title: "Copy as Markdown", image: UIImage(systemName: "text.document")) { _ in UIPasteboard.general.string = turn.answerMarkdown },
                    UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise")) { _ in store.retry(turn) },
                ]
                if let retryWith = RetryModelChoice(store: store, turn: turn) { items.append(retryWith.uiMenu) }
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
            actions.menu = { nil }
        default:
            break
        }
        let rowID = row.id
        actions.hit = { hit in
            guard case .toggle(let key) = hit else { return }
            // A tool row, group or thought opens as its SwiftUI row's own button opens it: the
            // line held where it is drawn, the body growing down from under it.
            if key.hasPrefix("tool-") || key.hasPrefix("group-") || key.hasPrefix("thought-") {
                context.toggleFold(row: rowID, key: key, open: true)
            } else {
                ChatMotion.set { disclosures.set(key, true) }
            }
        }
    }

    /// The card's files that are marked viewed, by index.
    static func viewed(_ changes: DiffChangeSet) -> Set<Int> {
        Set(changes.files.indices.filter { DiffViewedStore.shared.isViewed(key: viewedKey(changes.files[$0], in: changes.id)) })
    }

    /// `DiffViewedStore.key(for:)` per file, computed once (it hashes every line).
    private static var viewedKeys: [String: (lines: Int, additions: Int, key: String)] = [:]

    static func viewedKey(_ file: DiffFile, in changeSetID: String) -> String {
        let id = changeSetID + "\u{0}" + file.path
        if let cached = viewedKeys[id], cached.lines == file.lines.count, cached.additions == file.additions { return cached.key }
        let key = DiffViewedStore.key(for: file)
        if viewedKeys.count > 512 { viewedKeys = [:] }
        viewedKeys[id] = (file.lines.count, file.additions, key)
        return key
    }
}

/// Runs a change in the transcript's smooth spring (no animation with Reduce Motion).
@MainActor
enum ChatMotion {
    static func set(_ change: () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            change()
        } else {
            withAnimation(.cmuxMobileSmooth) { change() }
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
