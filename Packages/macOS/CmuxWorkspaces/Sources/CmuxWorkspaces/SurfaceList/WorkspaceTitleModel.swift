public import Foundation

/// The per-workspace title sub-model: owns the custom-title and
/// custom-description state-transition logic the legacy `Workspace` god object
/// kept inline (`setCustomTitle`, `setCustomDescription`, `applyProcessTitle`,
/// the `hasCustomTitle` / `effectiveCustomTitleSource` / `hasCustomDescription`
/// derivations, and the `normalizedCustomDescription` normalizer).
///
/// The title vocabulary it reads and writes (`title`, `customTitle`,
/// `customTitleSource`, `customDescription`, `processTitle`) is the workspace's
/// `@Published` state, whose `objectWillChange` emissions drive the UI, so the
/// model reaches each property through ``WorkspaceTitleHosting``, conformed by
/// `Workspace` and injected via ``attach(host:)``.
///
/// `Workspace` owns one instance and forwards each former method through a
/// one-line call, so every call site stays byte-identical. There is no
/// observer-parity bridge here: the writes go straight through the host's own
/// `@Published` properties, preserving their emission moments exactly as the
/// legacy bodies did.
@MainActor
public final class WorkspaceTitleModel {
    private weak var host: (any WorkspaceTitleHosting)?

    /// Creates a detached model; call ``attach(host:)`` before any title
    /// transition runs.
    public init() {}

    /// Injects the live-workspace seam. Set at the composition point before any
    /// title transition runs so the reads and writes reach the workspace.
    public func attach(host: any WorkspaceTitleHosting) {
        self.host = host
    }

    /// Whether a non-empty custom title is set (legacy
    /// `Workspace.hasCustomTitle`).
    public var hasCustomTitle: Bool {
        let trimmed = host?.workspaceTitleCustomTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    /// The provenance of the current custom title, normalizing legacy state:
    /// `nil` when no custom title is set; `.user` when a title exists but
    /// provenance was never recorded (pre-provenance snapshots, carried moves).
    /// Faithful lift of `Workspace.effectiveCustomTitleSource`.
    public var effectiveCustomTitleSource: CustomTitleSource? {
        hasCustomTitle ? (host?.workspaceTitleCustomTitleSource ?? .user) : nil
    }

    /// Whether a non-empty custom description is set (legacy
    /// `Workspace.hasCustomDescription`).
    public var hasCustomDescription: Bool {
        Self.normalizedCustomDescription(host?.workspaceTitleCustomDescription) != nil
    }

    /// Records a new process-reported `title` and, when no custom title masks
    /// it, promotes it to the workspace title. Faithful lift of
    /// `Workspace.applyProcessTitle(_:)`.
    public func applyProcessTitle(_ title: String) {
        guard let host else { return }
        if host.workspaceTitleProcessTitle != title {
            host.workspaceTitleProcessTitle = title
        }
        guard host.workspaceTitleCustomTitle == nil else { return }
        guard host.workspaceTitleText != title else { return }
        host.workspaceTitleLogApplyProcess(from: host.workspaceTitleText, to: title)
        host.workspaceTitleText = title
    }

    /// Normalizes a custom description's line endings to `\n` and trims it,
    /// returning `nil` for an empty/whitespace-only result (so the line-ending
    /// normalization is preserved while empties become `nil`). Faithful lift of
    /// the private `Workspace.normalizedCustomDescription(_:)`; `nonisolated`
    /// because it is a pure string transform that touches no model state.
    public nonisolated static func normalizedCustomDescription(_ description: String?) -> String? {
        let normalizedLineEndings = description?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalizedLineEndings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return normalizedLineEndings
    }

    /// Sets, replaces, or clears (empty/nil `title`) the workspace custom title.
    ///
    /// `.auto` writes are rejected when a user-set title exists, and `.auto`
    /// never clears. Returns whether the write landed. Faithful lift of
    /// `Workspace.setCustomTitle(_:source:)`.
    @discardableResult
    public func setCustomTitle(_ title: String?, source: CustomTitleSource = .user) -> Bool {
        guard let host else { return false }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if source == .auto {
            guard !trimmed.isEmpty else { return false }
            if hasCustomTitle, (host.workspaceTitleCustomTitleSource ?? .user) == .user { return false }
        }
        if trimmed.isEmpty {
            host.workspaceTitleCustomTitle = nil
            host.workspaceTitleCustomTitleSource = nil
            host.workspaceTitleText = host.workspaceTitleProcessTitle
        } else {
            host.workspaceTitleCustomTitle = trimmed
            host.workspaceTitleCustomTitleSource = source
            host.workspaceTitleText = trimmed
        }
        return true
    }

    /// Sets or clears the workspace custom description, normalizing line endings
    /// and emptiness. Faithful lift of `Workspace.setCustomDescription(_:)`.
    public func setCustomDescription(_ description: String?) {
        guard let host else { return }
        let normalizedDescription = Self.normalizedCustomDescription(description)
        host.workspaceTitleLogCustomDescriptionUpdate(input: description, normalized: normalizedDescription)
        host.workspaceTitleCustomDescription = normalizedDescription
    }
}
