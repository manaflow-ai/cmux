#if os(iOS)
import SwiftUI
import UIKit

/// How a bubble this phone sent, that the Mac has not shown yet, marks a send that is slow
/// (`retrying`, after 2 s unwritten) or given up (`failed`). Each is an overlay: the bubble's
/// size and place never change. A `sent` look draws nothing (it looks delivered).
public enum ChatPendingMarkStyle: String, CaseIterable, Sendable {
    /// A small glyph beside the bubble's lower leading corner (shipped).
    case glyph
    /// A thin border on the bubble's edge: dashed while retrying, solid once failed.
    case edge
    /// A line of caption text just under the bubble.
    case caption

    /// The style the transcript draws.
    public static let shipped: ChatPendingMarkStyle = .glyph

    /// The shipped style, or in DEBUG a gallery variant (`-cmux-mobile-pending-mark-variant
    /// glyph|edge|caption`, PendingMarkGalleryUITests).
    static let current: ChatPendingMarkStyle = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-cmux-mobile-pending-mark-variant"), args.indices.contains(i + 1),
           let style = ChatPendingMarkStyle(rawValue: args[i + 1]) {
            return style
        }
        #endif
        return shipped
    }()
}

struct ChatPendingMark: ViewModifier {
    let look: AgentPromptLook?
    var style: ChatPendingMarkStyle = .current

    @ViewBuilder
    func body(content: Content) -> some View {
        if let look, look != .sent {
            let failed = look == .failed
            let tint: Color = failed ? Color(uiColor: .systemRed).opacity(0.85) : Color(uiColor: .tertiaryLabel)
            let label = failed ? String(localized: "Not sent") : String(localized: "Waiting to send")
            switch style {
            case .glyph:
                content.overlay(alignment: .bottomLeading) {
                    Image(systemName: failed ? "exclamationmark.circle" : "clock")
                        .font(.footnote)
                        .foregroundStyle(tint)
                        .alignmentGuide(.leading) { $0[.trailing] + 6 }
                        .padding(.bottom, 6)
                        .accessibilityLabel(label)
                }
            case .edge:
                content.overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: failed ? [] : [5, 4]))
                        .accessibilityLabel(label)
                }
            case .caption:
                content.overlay(alignment: .bottomTrailing) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(tint)
                        .fixedSize()
                        .alignmentGuide(.bottom) { $0[.top] - 3 }
                }
            }
        } else {
            content
        }
    }
}

/// The menu on a bubble this phone sent that the Mac has not shown yet (the queue's
/// ChatCancelStep / ChatEditStep): Cancel, Edit, Retry Now, Delete.
@MainActor
enum ChatPendingMenu {
    static func items(_ promptID: String?, store: AgentChatStore) -> [UIMenuElement] {
        guard let promptID, let pending = store.pendingPrompt(promptID), pending.removal == nil else { return [] }
        let actions: [UIMenuElement] = [
            UIAction(title: String(localized: "Cancel"), image: UIImage(systemName: "arrow.uturn.backward")) { _ in
                store.cancelPending(promptID)
            },
            UIAction(title: String(localized: "Edit"), image: UIImage(systemName: "pencil")) { _ in
                presentEdit(promptID, store: store)
            },
            UIAction(title: String(localized: "Retry Now"), image: UIImage(systemName: "arrow.clockwise")) { _ in
                store.retryPending(promptID)
            },
            UIAction(title: String(localized: "Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                store.deletePending(promptID)
            },
        ]
        let title = switch pending.look {
        case .sent: ""
        case .retrying: String(localized: "Waiting to send")
        case .failed: pending.reason ?? String(localized: "Not sent")
        }
        return [UIMenu(title: title, options: .displayInline, children: actions)]
    }

    /// Edit on the bubble: its text in an alert (as Edit queued prompt), saved in its place.
    static func presentEdit(_ promptID: String, store: AgentChatStore) {
        guard let pending = store.pendingPrompt(promptID) else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top else { return }
        let alert = UIAlertController(title: String(localized: "Edit message"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = pending.text
            // Prompts are code-like: no capitals (as the queue's edit field).
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        let save = UIAlertAction(title: String(localized: "Save"), style: .default) { [weak alert] _ in
            store.editPending(promptID, text: alert?.textFields?.first?.text ?? "")
        }
        alert.addAction(save)
        alert.preferredAction = save
        top.present(alert, animated: true)
    }
}
#endif
