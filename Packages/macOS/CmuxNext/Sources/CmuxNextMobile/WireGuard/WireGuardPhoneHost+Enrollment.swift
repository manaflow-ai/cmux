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
        do {
            let phone = try enroll(request)
            let response = EnrollmentResponse(address: phone.address, presharedKey: phone.presharedKey, deviceID: phone.id)
            try await stream.write(JSONLine().encode(response))
            logger.info("wireguard: paired \(phone.name, privacy: .public) at \(phone.address, privacy: .public)")
        } catch {
            try? await stream.write(JSONLine().encode(EnrollmentResponse(error: error.localizedDescription)))
        }
        invitationExpiry.cancel()
        dropInvitation()
        publish()
    }

    /// Adds (or re-adds) the phone's permanent peer and saves it.
    private func enroll(_ request: EnrollmentRequest) throws -> WireGuardPairedPhone {
        guard var state, let tunnel else { throw PairingError.unreachable }
        // The same phone pairing again keeps its id and address.
        let existing = state.phones.firstIndex { $0.publicKey == request.publicKey }
        let used = Set(state.phones.map(\.address))
        guard let address = existing.map({ state.phones[$0].address })
                ?? (2...254).lazy.compactMap({ self.plan.deviceAddress($0) }).first(where: { !used.contains($0) }) else {
            throw PairingError.refused("This Mac has no room for another phone. Unpair one first.")
        }
        let phone = WireGuardPairedPhone(
            id: existing.map { state.phones[$0].id } ?? UUID().uuidString.lowercased(),
            name: String(request.deviceName.prefix(80)), model: String(request.deviceModel.prefix(80)),
            publicKey: request.publicKey, presharedKey: WireGuardKey(randomPresharedKey: ()),
            address: address, pairedAt: Date())
        try tunnel.setPeer(Self.peer(for: phone))
        if let existing { state.phones[existing] = phone } else { state.phones.append(phone) }
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
            if let newline = buffer.firstIndex(of: 0x0A) {
                return buffer[buffer.startIndex..<newline]
            }
        }
        return nil
    }
}
