import AppKit

enum TerminalClipboardAccessOperation: Equatable, Sendable {
    case read
    case write

    var title: String {
        switch self {
        case .read:
            return String(
                localized: "terminal.clipboardAccess.read.title",
                defaultValue: "Allow Clipboard Read?"
            )
        case .write:
            return String(
                localized: "terminal.clipboardAccess.write.title",
                defaultValue: "Allow Clipboard Change?"
            )
        }
    }

    var message: String {
        switch self {
        case .read:
            return String(
                localized: "terminal.clipboardAccess.read.message",
                defaultValue: "A program in this terminal wants to read these clipboard contents."
            )
        case .write:
            return String(
                localized: "terminal.clipboardAccess.write.message",
                defaultValue: "A program in this terminal wants to replace your clipboard with these contents."
            )
        }
    }
}

@MainActor
protocol TerminalClipboardAccessRequesting: AnyObject {
    func requestApproval(
        operation: TerminalClipboardAccessOperation,
        contents: String,
        window: NSWindow?,
        completion: @escaping (Bool) -> Void
    )
}

@MainActor
enum TerminalClipboardRuntimeBridge {
    static func handleWrite(
        contents: String,
        requiresConfirmation: Bool,
        window: NSWindow?,
        requester: any TerminalClipboardAccessRequesting,
        write: @escaping () -> Void
    ) {
        guard requiresConfirmation else {
            write()
            return
        }

        requester.requestApproval(
            operation: .write,
            contents: contents,
            window: window
        ) { approved in
            guard approved else { return }
            write()
        }
    }

    static func handleReadConfirmation(
        contents: String,
        window: NSWindow?,
        requester: any TerminalClipboardAccessRequesting,
        complete: @escaping (_ contents: String, _ confirmed: Bool) -> Void
    ) {
        requester.requestApproval(
            operation: .read,
            contents: contents,
            window: window
        ) { approved in
            complete(approved ? contents : "", true)
        }
    }
}

enum TerminalClipboardAccessPromptText {
    static let maximumVisibleScalarCount = 4_096

    static func preview(_ contents: String) -> String {
        var result = ""
        result.reserveCapacity(min(contents.utf8.count, maximumVisibleScalarCount))

        for (index, scalar) in contents.unicodeScalars.enumerated() {
            guard index < maximumVisibleScalarCount else {
                result.append("\n…")
                break
            }

            switch scalar.value {
            case 0x09, 0x0A:
                result.unicodeScalars.append(scalar)
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .surrogate, .privateUse, .unassigned:
                    result.append(
                        contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
                    )
                default:
                    result.unicodeScalars.append(scalar)
                }
            }
        }

        return result
    }
}

@MainActor
final class TerminalClipboardAccessPrompter: TerminalClipboardAccessRequesting {
    static let shared = TerminalClipboardAccessPrompter()

    private final class PendingApproval {
        let operation: TerminalClipboardAccessOperation
        let contents: String
        weak var window: NSWindow?
        let completion: (Bool) -> Void

        init(
            operation: TerminalClipboardAccessOperation,
            contents: String,
            window: NSWindow,
            completion: @escaping (Bool) -> Void
        ) {
            self.operation = operation
            self.contents = contents
            self.window = window
            self.completion = completion
        }
    }

    private var pendingApprovals: [PendingApproval] = []
    private var isPresenting = false

    func requestApproval(
        operation: TerminalClipboardAccessOperation,
        contents: String,
        window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window, window.isVisible else {
            completion(false)
            return
        }

        pendingApprovals.append(
            PendingApproval(
                operation: operation,
                contents: contents,
                window: window,
                completion: completion
            )
        )
        presentNextIfPossible()
    }

    private func presentNextIfPossible() {
        guard !isPresenting else { return }

        while !pendingApprovals.isEmpty {
            let approval = pendingApprovals.removeFirst()
            guard let window = approval.window,
                  window.isVisible,
                  window.attachedSheet == nil else {
                approval.completion(false)
                continue
            }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = approval.operation.title
            alert.addButton(
                withTitle: String(
                    localized: "common.cancel",
                    defaultValue: "Cancel"
                )
            )
            alert.addButton(
                withTitle: String(
                    localized: "common.allow",
                    defaultValue: "Allow"
                )
            )

            let preview = TerminalClipboardAccessPromptText.preview(approval.contents)
            let alertContent: CmuxAlertContent
            if preview.isEmpty {
                alertContent = CmuxAlertContent(informativeText: approval.operation.message)
            } else {
                let flattenedText = "\(approval.operation.message)\n\n\(preview)"
                alertContent = CmuxAlertContent(
                    flattenedText: flattenedText,
                    separatingScrollableDetails: preview
                )
            }
            alertContent.apply(to: alert, presentingWindow: window)

            isPresenting = true
            alert.beginSheetModal(for: window) { [weak self] response in
                approval.completion(response == .alertSecondButtonReturn)
                self?.isPresenting = false
                self?.presentNextIfPossible()
            }
            return
        }
    }
}
