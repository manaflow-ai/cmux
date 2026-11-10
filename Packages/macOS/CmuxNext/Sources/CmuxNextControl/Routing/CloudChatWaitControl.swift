public import CmuxNextDaemon

/// `cloud.chat_wait {machine, tab, after_seq?, timeout_ms?}`: a Cloud chat tab's turn pushed over the machine's
/// existing link (``AgentSessionAttachClient/turnRecords(after:within:)``), so `cmux cloud start-chat --wait` reads the
/// reply in one call instead of polling `cloud exec ... acp wait` and `acp last` (Leo, 2026-11-10: "have we figured out
/// where the 26.5 seconds were yet?"). Answers `{records, last_seq, ended, reason?}`; a tab the app cannot observe on
/// that machine is `chat_wait.unavailable`, and the CLI reads the turn through exec instead.
public enum CloudChatWaitControl {
    public static let maxWait: Duration = .seconds(60)
    /// The observing client of tab `tab` on Cloud machine `machine` (``AgentSessionAttachClient/Mode/observe``), or nil.
    public typealias Observer = @Sendable (_ machine: String, _ tab: String) async -> AgentSessionAttachClient?

    public static func method(_ observer: @escaping Observer) -> ControlMethod {
        .async("cloud.chat_wait") { call in
            guard let machine = call.params["machine"]?.stringValue, let tab = call.params["tab"]?.stringValue else { throw ControlError.invalidParams("needs machine and tab") }
            let wait = min(maxWait, .milliseconds(AgentSessionAttachClient.TurnRecords.count(call.params["timeout_ms"]) ?? 20_000))
            guard let client = await observer(machine, tab) else { throw ControlError(code: "chat_wait.unavailable", message: "no observable chat tab \(tab) on machine \(machine)") }
            let got: AgentSessionAttachClient.TurnRecords
            do { got = try await client.turnRecords(after: AgentSessionAttachClient.TurnRecords.count(call.params["after_seq"]), within: wait) } catch { await client.close(); throw error }
            await client.close()
            var answer: [String: JSONValue] = ["records": .array(got.records), "last_seq": .number(Double(got.lastSeq)), "ended": .string(got.ended ?? "timeout")]
            if let reason = got.reason { answer["reason"] = .string(reason) }
            return .object(answer)
        }.withDeadline(.fixed(maxWait + .seconds(10)))
    }
}
