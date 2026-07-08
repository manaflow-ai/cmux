import AppKit

@MainActor
final class PaneDropRoutingRegistration {
    private weak var owner: WindowTerminalHostView?
    private var sequenceNumber: Int?

    func update(_ sender: any NSDraggingInfo, operation: NSDragOperation, targetView: NSView) {
        guard let host = targetView.enclosingWindowTerminalHostView else {
            clear(sender)
            return
        }

        if host.updateActivePaneDropRoutingSession(sender, operation: operation) {
            owner = host
            sequenceNumber = sender.draggingSequenceNumber
        } else if sequenceNumber == sender.draggingSequenceNumber {
            clear(sender)
        }
    }

    func clear(_ sender: (any NSDraggingInfo)? = nil) {
        if let sender {
            owner?.clearActivePaneDropRoutingSession(sender)
            if sequenceNumber == sender.draggingSequenceNumber {
                sequenceNumber = nil
                owner = nil
            }
            return
        }

        guard let sequenceNumber else { return }
        owner?.clearActivePaneDropRoutingSession(sequenceNumber: sequenceNumber)
        self.sequenceNumber = nil
        owner = nil
    }
}

private extension NSView {
    var enclosingWindowTerminalHostView: WindowTerminalHostView? {
        var candidate = superview
        while let view = candidate {
            if let host = view as? WindowTerminalHostView {
                return host
            }
            candidate = view.superview
        }
        return nil
    }
}
