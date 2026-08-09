package com.cmux;

import java.util.Map;
import java.util.Objects;

/** Open typed union for terminal attachment items. */
public sealed interface TerminalAttachmentItem permits
        TerminalAttachmentItem.Snapshot,
        TerminalAttachmentItem.Patch,
        TerminalAttachmentItem.Scroll,
        TerminalAttachmentItem.Unknown {
    String kind();

    record Snapshot(
        Ids.TerminalId terminalId,
        Render.Snapshot render
    ) implements TerminalAttachmentItem {
        public Snapshot {
            Objects.requireNonNull(terminalId, "terminalId");
            Objects.requireNonNull(render, "render");
        }

        @Override
        public String kind() {
            return "snapshot";
        }
    }

    record Patch(
        Ids.TerminalId terminalId,
        Render.Patch render
    ) implements TerminalAttachmentItem {
        public Patch {
            Objects.requireNonNull(terminalId, "terminalId");
            Objects.requireNonNull(render, "render");
        }

        @Override
        public String kind() {
            return "patch";
        }
    }

    record Scroll(
        Ids.TerminalId terminalId,
        Render.Scroll scroll
    ) implements TerminalAttachmentItem {
        public Scroll {
            Objects.requireNonNull(terminalId, "terminalId");
            Objects.requireNonNull(scroll, "scroll");
        }

        @Override
        public String kind() {
            return "scroll";
        }
    }

    record Unknown(String kind, Map<String, Object> raw)
            implements TerminalAttachmentItem {
        public Unknown {
            unknown(kind, "snapshot", "patch", "scroll");
            raw = JsonValue.immutableObject(raw, "unknown terminal attachment");
        }
    }

    private static void unknown(String kind, String... recognized) {
        Objects.requireNonNull(kind, "kind");
        if (kind.isEmpty() || java.util.List.of(recognized).contains(kind)) {
            throw new IllegalArgumentException(
                "unknown item requires an unrecognized non-empty kind"
            );
        }
    }
}
