import Foundation

/// The answer of a harness's backend check on this Mac's acpmux (`_acpmux/harness/doctor`, one
/// real hello turn), as the Chief Settings popover shows it.
nonisolated public enum HomeHarnessCheck: Equatable, Sendable {
    case passed
    /// The first step that failed (`launch`, `initialize`, `session`, `prompt`, ...) and the
    /// doctor's words for why, so the note names what to fix.
    case failed(step: String, detail: String)

    /// The longest reason the note shows; the doctor's own output (Settings > Agents) has the rest.
    static let detailLimit = 160

    /// Runs `doctor` and reads its answer (`harness_admin::doctor_value`: `{ok, steps: [{name, ok,
    /// detail}]}`) as passed or its first failing step. A doctor that throws fails at `doctor` with
    /// `describe`'s text; no answer (the app is closing) fails at `doctor` with no reason.
    @MainActor
    public init(describe: @MainActor (any Error) -> String, doctor: @MainActor () async throws -> (some Encodable)?) async {
        do {
            guard let answer = try await doctor() else { self = .failed(step: "doctor", detail: ""); return }
            self = Self(answer: try JSONDecoder().decode(DoctorAnswer.self, from: JSONEncoder().encode(answer)))
        } catch {
            self = .failed(step: "doctor", detail: describe(error))
        }
    }

    init(answer: DoctorAnswer) {
        if answer.ok == true { self = .passed; return }
        let failed = answer.steps?.first { $0.ok == false }
        self = .failed(step: failed?.name ?? "doctor", detail: failed?.detail ?? "")
    }

    /// The note's reason: the detail's first line, cut to ``detailLimit``.
    var shortDetail: String? {
        guard case let .failed(_, detail) = self else { return nil }
        let line = detail.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        guard line.count > Self.detailLimit else { return line }
        return String(line.prefix(Self.detailLimit - 1)) + "…"
    }

    /// The part of the doctor's answer the check reads.
    struct DoctorAnswer: Decodable {
        struct Step: Decodable {
            let name: String?
            let ok: Bool?
            let detail: String?
        }

        let ok: Bool?
        let steps: [Step]?
    }
}
