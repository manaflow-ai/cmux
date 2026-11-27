public import CmuxNextDaemon

extension DaemonService {
    /// A theme file's `slots`, read and checked by the daemon (`theme.slots.resolve`): slot id to
    /// variant id, which the pages get as is. Waits for the daemon to be live; any failure is no slots.
    public func resolveThemeSlots(name: String, text: String) async -> [String: String] {
        await untilLive()
        guard let connection,
              let reply = try? await ResourceRelayClient(connection: connection).send(
                  operation: "theme.slots.resolve",
                  params: ["machine": .string("current"), "session": .string("current"), "name": .string(name), "text": .string(text)],
                  idempotencyKey: nil),
              case .object(let slots)? = (reply["value"] ?? reply)["slots"] else { return [:] }
        return slots.compactMapValues { if case .string(let variant) = $0 { variant } else { nil } }
    }
}
