public import Foundation

/// Carries a per-terminal event lane's identity to the phone's event decoder.
///
/// The phone reads each terminal's event lane separately but decodes all of
/// them from one merged byte stream. Before forwarding a lane's frames, the
/// reader writes a scope frame naming the lane's terminal, and a closing scope
/// frame after them. The decoder then refuses any event inside a scope whose
/// payload names another terminal, so a frame routed onto the wrong lane can
/// never be drawn into another terminal. The terminal it did name misses a
/// revision and resyncs through its own chain.
///
/// Scope frames exist only inside the phone; they never cross the network.
public enum MobileEventLaneScope {
    public static let kind = "lane"
    public static let surfaceKey = "surface_id"

    /// A framed scope marker: `surfaceID` opens a lane's scope, nil closes it.
    public static func frame(surfaceID: String?) -> Data {
        var envelope: [String: Any] = ["kind": kind]
        if let surfaceID { envelope[surfaceKey] = surfaceID }
        let payload = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return (try? MobileSyncFrameCodec.encodeFrame(payload)) ?? Data()
    }

    /// Wraps whole frames read from one terminal's lane in its scope.
    public static func scoped(_ frames: Data, surfaceID: String) -> Data {
        var scoped = frame(surfaceID: surfaceID)
        scoped.append(frames)
        scoped.append(frame(surfaceID: nil))
        return scoped
    }

    /// The scope a decoded envelope opens (`.some(id)`) or closes
    /// (`.some(nil)`), or nil when the envelope is not a scope frame.
    public static func scopeChange(in envelope: [String: Any]) -> String?? {
        guard envelope["kind"] as? String == kind else { return nil }
        return .some(envelope[surfaceKey] as? String)
    }

    /// Whether an event decoded inside `scope` belongs to that terminal.
    public static func eventBelongs(payload: Any?, toScope scope: String) -> Bool {
        guard let payload = payload as? [String: Any],
              let surfaceID = payload[surfaceKey] as? String else { return false }
        return normalized(surfaceID) == normalized(scope)
    }

    private static func normalized(_ surfaceID: String) -> String {
        surfaceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
