public import Foundation

/// Names a person reads for the ids a Chief's engine reports (Leo 2026-10-21, #89: the Chief
/// settings showed `claude-sr2-pipe` and `claude-opus-5-5`). An official engine keeps its own
/// title (``ChiefBackend/title``) and a model the catalog names keeps that name; these are the
/// fallback for every other id, so a raw id never shows as a title. The raw id stays in a
/// tooltip or a detail line where one helps. The rules are Rust's `chief_settings.harnessName`
/// and `chief_settings.modelName` (cmux-home-rules `chief_settings/names.rs`).
extension String {
    /// A harness id as a name: the official engine or acpmux built-in it starts with, then the
    /// rest in brackets (`claude-sr2-pipe` → "Claude (SR2 Pipe)", `claude-cr` → "Claude
    /// (CodeRouter)", `gemini` → "Gemini CLI"). A blank id comes back as it is.
    public nonisolated var chiefHarnessName: String {
        (try? HomeRules.call("chief_settings.harnessName", ChiefNameRequest(id: self, strings: .official))) ?? self
    }

    /// A model id as a name: words capitalized, a version's numbers joined by a dot, a trailing
    /// release date (`20250929` or `2024-08-06`, a real month and day) dropped, and a context suffix kept (`claude-opus-5-5` → "Claude Opus 5.5",
    /// `claude-sonnet-4-5-20250929` → "Claude Sonnet 4.5", `gpt-5.1-codex` → "GPT 5.1 Codex",
    /// `opus[1m]` → "Opus (1M)"). A blank id comes back as it is.
    public nonisolated var chiefModelName: String {
        (try? HomeRules.call("chief_settings.modelName", ChiefNameRequest(id: self, strings: nil))) ?? self
    }
}

/// `chief_settings.harnessName` / `modelName` / `backendTitle`'s request.
nonisolated struct ChiefNameRequest: Encodable {
    var id: String
    var strings: ChiefBackendStrings?
}

/// The official engines' localized titles and hints, the `strings` the names ops read.
nonisolated struct ChiefBackendStrings: Encodable {
    var backends: [String: String]
    var hints: [String: String]

    static var official: ChiefBackendStrings {
        var titles: [String: String] = [:]
        var hints: [String: String] = [:]
        for backend in ChiefBackend.official {
            titles[backend.id] = backend.title
            hints[backend.id] = backend.hint
        }
        return ChiefBackendStrings(backends: titles, hints: hints)
    }
}
