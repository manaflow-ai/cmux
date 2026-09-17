#if os(iOS) && DEBUG
import Foundation

/// Debug-only timestamps for the user-visible release-gate path.
@MainActor
public enum MobileReleaseGateUIProbe {
    public enum EventKind: String, Sendable {
        case appRootVisible
        case workspaceListVisible
        case workspaceDetailVisible
        case terminalFramePresented
    }

    public struct Event: Sendable {
        public let kind: EventKind
        public let uptimeNanoseconds: UInt64

        init(kind: EventKind, uptimeNanoseconds: UInt64) {
            self.kind = kind
            self.uptimeNanoseconds = uptimeNanoseconds
        }
    }

    private static var startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    private static var events: [Event] = []

    public static func reset() {
        startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        events.removeAll(keepingCapacity: true)
    }

    public static func record(_ kind: EventKind) {
        events.append(Event(kind: kind, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds))
        if events.count > 64 { events.removeFirst(events.count - 64) }
    }

    public static func latencies() -> [String: Double] {
        let root = events.first(where: { $0.kind == .appRootVisible })?.uptimeNanoseconds
            ?? startedAtNanoseconds
        guard let list = events.first(where: { $0.kind == .workspaceListVisible }),
              list.uptimeNanoseconds >= root else { return [:] }
        var result = [
            "app_root_to_workspace_list_visible": seconds(list.uptimeNanoseconds - root),
        ]
        if let detail = events.first(where: {
            $0.kind == .workspaceDetailVisible && $0.uptimeNanoseconds >= list.uptimeNanoseconds
        }) {
            result["workspace_list_to_detail_visible"] = seconds(
                detail.uptimeNanoseconds - list.uptimeNanoseconds
            )
            if let terminal = events.first(where: {
                $0.kind == .terminalFramePresented && $0.uptimeNanoseconds >= detail.uptimeNanoseconds
            }) {
                result["workspace_detail_to_terminal_text_visible"] = seconds(
                    terminal.uptimeNanoseconds - detail.uptimeNanoseconds
                )
            }
        }
        return result
    }

    private static func seconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000_000
    }
}
#endif
