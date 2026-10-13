import CmuxNextWakeups
import CmuxWireGuard
import CmuxWireGuardPairing
import Foundation

extension WireGuardPhoneHost {
    /// Largest enrollment request accepted.
    static let maximumEnrollmentBytes = 16 * 1024

    /// One enrollment exchange from the current invitation's bootstrap peer:
    /// read one JSON line, add the phone's permanent peer, answer, and drop
    /// the bootstrap peer so the invitation cannot be used twice.
    func serveEnrollment(_ stream: SocketStream, from address: String) async {
        defer { stream.close() }
        guard plan.isBootstrapAddress(address), let pending = invitation,
              pending.invitation.bootstrapAddress == address else {
            return
        }
        // A bootstrap peer gets 10 s to send its request.
        let deadline = DemandTimer(owner: "mobile.wireguard.enrollment")
        deadline.schedule(after: .seconds(10)) { stream.close() }
        defer { deadline.cancel() }
        guard let line = await readLine(stream),
              let request = try? JSONLine().decode(EnrollmentRequest.self, from: line) else {
            try? await stream.write(JSONLine().encode(EnrollmentResponse(error: "Malformed pairing request.")))
            return
        }
        // The invitation may have expired or been replaced while the line arrived.
        guard invitation?.bootstrapPublicKey == pending.bootstrapPublicKey,
              Date() < pending.invitation.expiry else {
            try? await stream.write(JSONLine().encode(EnrollmentResponse(error: PairingError.expired.localizedDescription)))
            return
        }
        // Single use: retire the invitation now, before any await, so a
        // second request on it is refused.
        invitationExpiry.cancel()
        invitation = nil
        do {
            let phone = try enroll(request, bootstrapKey: pending.bootstrapPublicKey)
            let response = EnrollmentResponse(address: phone.address, presharedKey: phone.presharedKey, deviceID: phone.id)
            try await stream.write(JSONLine().encode(response))
            logger.info("wireguard: paired \(phone.name, privacy: .public) at \(phone.address, privacy: .public)")
        } catch {
            try? await stream.write(JSONLine().encode(EnrollmentResponse(error: error.localizedDescription)))
        }
        publish()
        // The answer still has to cross the tunnel through the bootstrap peer:
        // keep it until the phone closes the connection (it does once it has
        // read the answer) or the deadline closes it, then remove it.
        // wakeup-allow: drains to end of stream; the 10 s deadline closes it
        while let chunk = try? await stream.read(maximumBytes: 1024), !chunk.isEmpty {}
        try? tunnel?.removePeer(pending.bootstrapPublicKey)
    }

    /// Adds (or re-adds) the phone's permanent peer and saves it.
    private func enroll(_ request: EnrollmentRequest, bootstrapKey: WireGuardKey) throws -> WireGuardPairedPhone {
        guard var state, let tunnel else { throw PairingError.unreachable }
        // Keys that are not a phone's own: the Mac's, or an invitation's.
        guard request.publicKey != state.privateKey.publicKey, request.publicKey != bootstrapKey else {
            throw PairingError.refused("This pairing request is not valid.")
        }
        // A key that is already paired keeps its record unchanged: re-pairing
        // the same phone needs nothing new, and a request carrying another
        // phone's public key must not rotate that phone's preshared key.
        if let existing = state.phones.first(where: { $0.publicKey == request.publicKey }) {
            justPaired = existing
            return existing
        }
        let used = Set(state.phones.map(\.address))
        let retired = state.retiredAddresses ?? []
        let free = (2...254).compactMap { self.plan.deviceAddress($0) }.filter { !used.contains($0) }
        // Never-used addresses first, then retired ones, oldest first.
        guard let address = free.first(where: { !retired.contains($0) })
                ?? retired.first(where: { free.contains($0) }) else {
            throw PairingError.refused("This Mac has no room for another phone. Unpair one first.")
        }
        state.retiredAddresses = retired.filter { $0 != address }
        let phone = WireGuardPairedPhone(
            id: UUID().uuidString.lowercased(),
            name: String(request.deviceName.prefix(80)), model: String(request.deviceModel.prefix(80)),
            publicKey: request.publicKey, presharedKey: WireGuardKey(randomPresharedKey: ()),
            address: address, pairedAt: Date())
        try tunnel.setPeer(Self.peer(for: phone))
        state.phones.append(phone)
        try store.save(state)
        self.state = state
        justPaired = phone
        return phone
    }

    /// One newline-terminated line, or nil on end of stream or overflow.
    private func readLine(_ stream: SocketStream) async -> Data? {
        var buffer = Data()
        while buffer.count <= Self.maximumEnrollmentBytes {
            guard let chunk = try? await stream.read(maximumBytes: 4096) else { return nil }
            buffer.append(chunk)
            if buffer.contains(0x0A) {
                return Data(buffer.prefix { $0 != 0x0A })
            }
        }
        return nil
    }
}
