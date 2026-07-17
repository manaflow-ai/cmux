import Dispatch
import Foundation

@MainActor
final class WorkspacePendingTerminalInputObserver {
    var observer: NSObjectProtocol?
    var timeoutTimer: DispatchSourceTimer?
}
