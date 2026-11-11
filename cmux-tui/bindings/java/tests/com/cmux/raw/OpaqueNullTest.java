package com.cmux.raw;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Opaque JSON admits null, so a field that is not nullable must reject an
 * explicit null itself with {@link CmuxDecodeException}, never an NPE
 * (review finding F1 on #41287: first_tab on a create-workspace reply).
 */
public final class OpaqueNullTest {
    public static void main(String[] args) {
        optionalOpaqueFieldRejectsExplicitNull();
        optionalOpaqueFieldKeepsAbsenceAndValues();
        requiredOpaqueFieldRejectsExplicitNull();
    }

    private static Map<String, Object> mutationResult() {
        LinkedHashMap<String, Object> wire = new LinkedHashMap<>();
        wire.put("generation", "g");
        wire.put("index", 1L);
        wire.put("key", "k");
        wire.put("registry_id", "r");
        wire.put("replayed", false);
        wire.put("workspace", 1L);
        wire.put("workspace_revision", 1L);
        return wire;
    }

    private static void optionalOpaqueFieldRejectsExplicitNull() {
        Map<String, Object> wire = mutationResult();
        wire.put("first_tab", null);
        expectDecodeError(() -> WorkspaceMutationResult.fromWire(wire), "first_tab");
    }

    private static void optionalOpaqueFieldKeepsAbsenceAndValues() {
        WorkspaceMutationResult absent = WorkspaceMutationResult.fromWire(mutationResult());
        check(!absent.firstTab().isPresent(), "absent first_tab stays absent");

        Map<String, Object> wire = mutationResult();
        wire.put("first_tab", Map.of("kind", "browser"));
        WorkspaceMutationResult present = WorkspaceMutationResult.fromWire(wire);
        check(present.firstTab().isPresent(), "present first_tab decodes");
    }

    private static void requiredOpaqueFieldRejectsExplicitNull() {
        LinkedHashMap<String, Object> wire = new LinkedHashMap<>();
        wire.put("event", "conversation-draft");
        wire.put("conversation", "c");
        wire.put("participant", "p");
        wire.put("item", null);
        expectDecodeError(() -> ConversationDraftEvent.fromWire(wire), "item");
    }

    private static void expectDecodeError(Runnable decode, String field) {
        try {
            decode.run();
        } catch (CmuxDecodeException error) {
            check(error.getMessage().contains(field), "decode error names " + field + ": " + error.getMessage());
            return;
        }
        throw new AssertionError("explicit null " + field + " decoded without a CmuxDecodeException");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
