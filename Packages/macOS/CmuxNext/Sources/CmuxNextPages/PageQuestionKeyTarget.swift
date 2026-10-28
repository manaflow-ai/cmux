public import Foundation

/// One pending question read by the native agent-pane owner, never a page-supplied request.
/// The IDs identify the card; the isolated channel keeps its authentication secret separately.
public nonisolated struct PageQuestionKeyTarget: Hashable, Sendable {
    public let sessionID: String
    public let permissionID: String

    public init(sessionID: String, permissionID: String) {
        self.sessionID = sessionID
        self.permissionID = permissionID
    }

    var isValid: Bool {
        [sessionID, permissionID].allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\u{0}") }
    }
}

/// The private script used only by ``ChromiumQuestionKeyChannel``. The main world cannot read
/// its nonce or call its binding. DOM IDs are labels, not credentials; trusted key dispatch and
/// the native pending-question/person-key checks remain required.
nonisolated enum PageQuestionKeyScript {
    static let cleanup = "__cmuxQuestionKeyCleanup"
    static let maximumReplyBytes = ChromiumPageHostBridge.maximumPayloadBytes

    static func redemptionName(binding: String) -> String { binding + "_redeem" }

    static func source(targets: [PageQuestionKeyTarget], nonce: String, binding: String, generation: Int) -> String {
        let value = ChromiumPageHostWire.jsonString
        let allowed = targets.map { "[\(value($0.sessionID)),\(value($0.permissionID))]" }.joined(separator: ",")
        return """
        (() => {
          if ((globalThis.__cmuxQuestionKeyGeneration ?? -1) >= \(generation)) return;
          globalThis.__cmuxQuestionKeyGeneration = \(generation);
          globalThis.\(cleanup)?.();
          const allowed = new Set([\(allowed)].map((target) => JSON.stringify(target)));
          const nonce = \(value(nonce));
          const binding = \(value(binding));
          const redemption = \(value(redemptionName(binding: binding)));
          const post = globalThis[binding];
          let sequence = 0;
          let pending;
          const revoke = () => {
            if (!pending) return;
            pending.revoked = true;
            pending.observer.disconnect();
            pending.field.removeEventListener('focusout', revoke, true);
            pending.field.removeEventListener('input', revoke, true);
            pending = undefined;
          };
          const changed = (records, snapshot) => {
            if (!pending || pending !== snapshot) return;
            if (records.length > 64) { revoke(); return; }
            for (const record of records) {
              if (record.type === 'attributes') { revoke(); return; }
              // Watch only the original ancestor chain, without a subtree observer. Streaming
              // text elsewhere never scans rows. A huge replacement revokes conservatively.
              if (record.removedNodes.length > 32) { revoke(); return; }
              for (const removed of record.removedNodes) {
                if (pending.ancestors.has(removed)) { revoke(); return; }
              }
            }
          };
          const valid = (snapshot) => !snapshot.revoked && snapshot.field.isConnected && snapshot.card.isConnected &&
            snapshot.field === document.activeElement && snapshot.other.contains(snapshot.field) &&
            snapshot.card.contains(snapshot.other) && snapshot.other.getAttribute('data-row-editing') === 'true' &&
            snapshot.card.getAttribute('data-cmux-question-session') === snapshot.sessionID &&
            snapshot.card.getAttribute('data-cmux-question-id') === snapshot.permissionID &&
            snapshot.card.getAttribute('data-cmux-question-enter-reply') === snapshot.replyJSON &&
            snapshot.field.value === snapshot.text && !snapshot.card.hidden &&
            snapshot.field.getClientRects().length > 0 && snapshot.card.getClientRects().length > 0;
          globalThis[redemption] = (secret, serial, replyJSON) => {
            const snapshot = pending;
            if (!snapshot || secret !== nonce || snapshot.serial !== serial || snapshot.replyJSON !== replyJSON) return false;
            // takeRecords catches remove+reattach, focus/payload/label changes restored before
            // this call, without waiting for the observer callback to run.
            changed(snapshot.observer.takeRecords(), snapshot);
            const accepted = valid(snapshot);
            revoke();
            return accepted;
          };
          const key = (event) => {
            if (!event.isTrusted || event.repeat || event.isComposing || event.keyCode === 229 ||
                event.key !== 'Enter' || event.shiftKey || event.ctrlKey || event.altKey) return;
            const field = event.target;
            if (!(field instanceof HTMLTextAreaElement) || field !== document.activeElement || !field.isConnected) return;
            const path = event.composedPath();
            if (path[0] !== field) return;
            const other = field.closest('.acpmux-question-other[data-row-editing="true"]');
            const card = field.closest('.acpmux-question');
            if (!other || !card || !path.includes(other) || !path.includes(card) ||
                card.hidden || card.getAttribute('aria-busy') === 'true' ||
                field.getClientRects().length === 0 || card.getClientRects().length === 0) return;
            const sessionID = card.getAttribute('data-cmux-question-session');
            const permissionID = card.getAttribute('data-cmux-question-id');
            if (!allowed.has(JSON.stringify([sessionID, permissionID]))) return;
            revoke(); // Every newer genuine key revokes the previous unused proof.
            const replyJSON = card.getAttribute('data-cmux-question-enter-reply');
            if (typeof replyJSON !== 'string' || replyJSON.length > \(maximumReplyBytes)) return;
            let reply;
            try { reply = JSON.parse(replyJSON); } catch { return; }
            const object = (value) => value && typeof value === 'object' && !Array.isArray(value);
            if (!object(reply) || typeof reply.optionId !== 'string' || !reply.optionId || !object(reply.answers) ||
                Object.keys(reply).some((key) => !['optionId', 'answers', 'annotations'].includes(key)) ||
                ('annotations' in reply && !object(reply.annotations))) return;
            const observer = new MutationObserver((records) => changed(records, snapshot));
            const ancestors = new Set();
            for (let node = field; node; node = node.parentNode) {
              ancestors.add(node);
              observer.observe(node, {childList:true});
            }
            observer.observe(card, {attributes:true, childList:true, attributeFilter:[
              'data-cmux-question-session', 'data-cmux-question-id', 'data-cmux-question-enter-reply', 'hidden'
            ]});
            observer.observe(other, {attributes:true, childList:true, attributeFilter:['data-row-editing']});
            const snapshot = {card, field, other, ancestors, observer, sessionID, permissionID, replyJSON, text:field.value,
              serial:++sequence, revoked:false};
            pending = snapshot;
            field.addEventListener('focusout', revoke, true);
            field.addEventListener('input', revoke, true);
            // Capture runs before the card's handler. No page API receives a ticket or secret.
            post(JSON.stringify({ nonce, sequence, sessionID, permissionID, replyJSON }));
          };
          document.addEventListener('keydown', key, true);
          globalThis.\(cleanup) = (owner) => {
            if (owner !== undefined && owner !== binding) return;
            revoke();
            document.removeEventListener('keydown', key, true);
            delete globalThis[redemption];
            delete globalThis.\(cleanup);
          };
        })();
        """
    }
}
