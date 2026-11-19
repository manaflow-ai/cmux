import CmuxNextMobile

/// Pair requests that came before this Mac's paired list was in (the seal is read off the main actor,
/// and a Keychain that refuses it is waited for, about 30 s, ``MobileHostPairedStore/sealWaits``).
/// Nothing can be decided then: no phone is trusted, asked about or let in by a pairing code until the
/// list is known. A request was dropped there, so hostd waited out its 120 s for a prompt nobody showed
/// and the phone's single-use code went unused (2026-11-18, review.sh on a real iPhone: a launch right
/// after the tag's Mac app was replaced). The latest request of each phone is kept here and answered
/// once the list is in.
struct MobileHostHeldPairRequests: Sendable {
    private var byPhone: [String: MobileHostPairRequest] = [:]
    private var order: [String] = []

    /// Keeps `request`, in place of an earlier one from the same phone.
    mutating func hold(_ request: MobileHostPairRequest) {
        if byPhone.updateValue(request, forKey: request.phoneDeviceID) == nil { order.append(request.phoneDeviceID) }
    }

    /// The held requests, oldest phone first; none are held after this.
    mutating func release() -> [MobileHostPairRequest] {
        defer { byPhone = [:]; order = [] }
        return order.compactMap { byPhone[$0] }
    }

    var isEmpty: Bool { byPhone.isEmpty }
}
