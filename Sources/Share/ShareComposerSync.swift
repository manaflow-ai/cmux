import Foundation

/// Host-authoritative composer co-editing for agent-session panes (slice 2).
///
/// Each shared agent pane's composer is one "field", keyed by the pane's
/// panel UUID string. The host owns the canonical `(rev, text)`; guests send
/// `compose` ops against the rev they last saw and the host rebases stale ops
/// before applying.
///
/// Rebase rule (documented contract): ops carry a codepoint (unicode
/// scalar) position `p`, an
/// optional codepoint delete count `d`, and an optional insert string `i`
/// (delete runs
/// before insert at the same position). A guest op authored at rev R is
/// transformed against every host-applied edit with rev > R, in order. For
/// each such prior edit at position `q` deleting `dq` codepoints and inserting
/// `iq`:
///   - if `p >= q + dq`: shift `p` by `count(iq) - dq` (text moved).
///   - if `p >= q` (op lands inside the deleted range): clamp `p` to
///     `q + count(iq)` and drop the op's own delete (the region it meant
///     to delete no longer exists); the insert survives.
///   - if `p < q`: position unaffected.
/// This is a last-writer-wins positional transform, not full OT: concurrent
/// overlapping deletes may drop a guest delete, never corrupt indices. After
/// applying, the host bumps `rev` and broadcasts full `compose-state`, which
/// every client adopts verbatim, so divergence self-heals on the next state.
@MainActor
final class ShareComposerSync {
    struct FieldState {
        var rev: Int = 0
        var text: String = ""
        /// Last known caret per guest user id (codepoint offsets).
        var carets: [String: ShareCaretRange] = [:]
        /// Recent host-applied edits keyed by the rev they produced, kept for
        /// rebasing stale guest ops. Bounded (see `historyLimit`).
        var history: [(rev: Int, position: Int, deleted: Int, insertedScalars: Int)] = []
    }

    /// Broadcasts authoritative state after every applied change.
    var sendComposeState: ((_ field: String, _ rev: Int, _ text: String, _ carets: [ShareComposeCaret]) -> Void)?
    /// Pushes canonical text into the pane's web composer.
    var applyTextToPane: ((_ field: String, _ text: String) -> Void)?

    private var fields: [String: FieldState] = [:]
    private static let historyLimit = 128

    func reset() {
        fields = [:]
    }

    func removeField(_ field: String) {
        fields.removeValue(forKey: field)
    }

    /// Host-side composer change (the human typing into the pane). Adopt the
    /// text as canonical, bump rev, broadcast.
    func hostTextChanged(field: String, text: String) {
        var state = fields[field] ?? FieldState()
        guard state.text != text else { return }
        // A whole-text replacement has no precise op; record it as replace-all
        // so stale guest ops against older revs clamp sanely.
        let edit = (
            rev: state.rev + 1,
            position: 0,
            deleted: state.text.unicodeScalars.count,
            insertedScalars: text.unicodeScalars.count
        )
        state.text = text
        state.rev += 1
        state.history.append(edit)
        trimHistory(&state)
        fields[field] = state
        broadcast(field: field, state: state)
    }

    /// Applies a guest's ops (already role-validated by the caller): rebase
    /// each op across host edits newer than the guest's rev, apply, bump rev,
    /// push into the pane, broadcast.
    func applyGuestOps(
        field: String,
        user: String,
        baseRev: Int,
        ops: [ShareComposeOp],
        caret: ShareCaretRange?
    ) {
        var state = fields[field] ?? FieldState()
        var didChange = false
        for op in ops {
            let rebased = Self.rebase(op: op, against: state.history, baseRev: baseRev)
            guard let applied = Self.apply(op: rebased, to: state.text) else { continue }
            state.history.append((
                rev: state.rev + 1,
                position: rebased.p,
                deleted: rebased.d ?? 0,
                insertedScalars: (rebased.i ?? "").unicodeScalars.count
            ))
            state.text = applied
            state.rev += 1
            didChange = true
        }
        if let caret {
            let limit = state.text.unicodeScalars.count
            state.carets[user] = ShareCaretRange(
                start: min(max(0, caret.start), limit),
                end: min(max(0, caret.end), limit)
            )
        }
        trimHistory(&state)
        fields[field] = state
        if didChange {
            applyTextToPane?(field, state.text)
        }
        broadcast(field: field, state: state)
    }

    func removeParticipantCarets(user: String) {
        for field in fields.keys {
            fields[field]?.carets.removeValue(forKey: user)
        }
    }

    private func broadcast(field: String, state: FieldState) {
        let carets = state.carets
            .map { ShareComposeCaret(user: $0.key, start: $0.value.start, end: $0.value.end) }
            .sorted { $0.user < $1.user }
        sendComposeState?(field, state.rev, state.text, carets)
    }

    private func trimHistory(_ state: inout FieldState) {
        if state.history.count > Self.historyLimit {
            state.history.removeFirst(state.history.count - Self.historyLimit)
        }
    }

    // MARK: - Transform + apply (pure, testable)

    static func rebase(
        op: ShareComposeOp,
        against history: [(rev: Int, position: Int, deleted: Int, insertedScalars: Int)],
        baseRev: Int
    ) -> ShareComposeOp {
        var position = op.p
        var deleteCount = op.d
        for edit in history where edit.rev > baseRev {
            if position >= edit.position + edit.deleted {
                position += edit.insertedScalars - edit.deleted
            } else if position >= edit.position {
                // The op's anchor fell inside a deleted region: clamp to the
                // replacement's end and drop the op's own delete.
                position = edit.position + edit.insertedScalars
                deleteCount = nil
            }
        }
        return ShareComposeOp(p: max(0, position), d: deleteCount, i: op.i)
    }

    /// Applies one op to `text` in codepoint (unicode scalar) space; nil when
    /// the op is a no-op or malformed beyond clamping.
    static func apply(op: ShareComposeOp, to text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        let position = min(max(0, op.p), scalars.count)
        let deleteCount = min(max(0, op.d ?? 0), scalars.count - position)
        let insert = op.i ?? ""
        guard deleteCount > 0 || !insert.isEmpty else { return nil }
        var result = scalars
        result.removeSubrange(position..<(position + deleteCount))
        result.insert(contentsOf: Array(insert.unicodeScalars), at: position)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: result)
        return String(view)
    }
}
