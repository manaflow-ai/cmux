public import Foundation

/// One pending question read by the native agent-pane owner, never a page-supplied request.
/// The IDs identify the card; the isolated channel keeps its authentication secret separately.
public nonisolated struct PageQuestionKeyTarget: Equatable, Sendable {
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

    static func source(target: PageQuestionKeyTarget, nonce: String, binding: String, generation: Int) -> String {
        let value = ChromiumPageHostWire.jsonString
        return """
        (() => {
          if ((globalThis.__cmuxQuestionKeyGeneration ?? -1) >= \(generation)) return;
          globalThis.__cmuxQuestionKeyGeneration = \(generation);
          globalThis.\(cleanup)?.();
          const session = \(value(target.sessionID));
          const permission = \(value(target.permissionID));
          const nonce = \(value(nonce));
          const binding = \(value(binding));
          const post = globalThis[binding];
          let sequence = 0;
          const key = (event) => {
            if (!event.isTrusted || event.repeat || event.isComposing || event.keyCode === 229 ||
                event.key !== 'Enter' || event.shiftKey || event.ctrlKey || event.altKey) return;
            const field = event.target;
            if (!(field instanceof HTMLTextAreaElement) || field !== document.activeElement ||
                !field.closest('.acpmux-question-other') || field.getClientRects().length === 0) return;
            const card = field.closest('.acpmux-question');
            if (!card || card.hidden || card.getAttribute('aria-busy') === 'true' ||
                card.getAttribute('data-cmux-question-session') !== session ||
                card.getAttribute('data-cmux-question-id') !== permission ||
                card.getClientRects().length === 0) return;
            // Capture runs before the card's handler sends the answer. It grants no page API.
            post(JSON.stringify({ nonce, sequence: ++sequence }));
          };
          document.addEventListener('keydown', key, true);
          globalThis.\(cleanup) = (owner) => {
            if (owner !== undefined && owner !== binding) return;
            document.removeEventListener('keydown', key, true);
            delete globalThis.\(cleanup);
          };
        })();
        """
    }
}
