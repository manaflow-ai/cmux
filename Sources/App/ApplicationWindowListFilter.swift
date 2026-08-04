import CoreGraphics
import Darwin
import Foundation

/// Applies the host-owned policy for exposing native windows to application panes.
struct ApplicationWindowListFilter {
    private let excludedProcessIDs: Set<pid_t>
    private let isRegularApplication: (pid_t) -> Bool

    init(
        excludedProcessIDs: Set<pid_t>,
        isRegularApplication: @escaping (pid_t) -> Bool
    ) {
        self.excludedProcessIDs = excludedProcessIDs
        self.isRegularApplication = isRegularApplication
    }

    func entry(_ window: [String: Any]) -> [String: Any]? {
        guard
            let rawWindowID = window[kCGWindowNumber as String] as? NSNumber,
            rawWindowID.uint64Value > 0,
            rawWindowID.uint64Value <= UInt32.max,
            let rawProcessID =
                window[kCGWindowOwnerPID as String] as? NSNumber,
            rawProcessID.int64Value > 0,
            rawProcessID.int64Value <= Int32.max,
            let owner = window[kCGWindowOwnerName as String] as? String,
            !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            window[kCGWindowIsOnscreen as String] as? Bool == true,
            let sharingState =
                window[kCGWindowSharingState as String] as? NSNumber,
            sharingState.intValue != 0,
            let bounds =
                window[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: bounds)
        else {
            return nil
        }
        let processID = pid_t(rawProcessID.int32Value)
        let alpha = (
            window[kCGWindowAlpha as String] as? NSNumber
        )?.doubleValue ?? 1
        guard
            !excludedProcessIDs.contains(processID),
            isRegularApplication(processID),
            alpha.isFinite,
            alpha > 0.01,
            frame.width.isFinite,
            frame.height.isFinite,
            (64...16_384).contains(frame.width),
            (64...16_384).contains(frame.height)
        else {
            return nil
        }
        let title = (
            window[kCGWindowName as String] as? String
        ).flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : value
        } ?? owner
        return [
            "window_id": rawWindowID.intValue,
            "process_id": Int(processID),
            "owner": owner,
            "title": title,
            "width": frame.width,
            "height": frame.height,
        ]
    }
}
