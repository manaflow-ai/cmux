package com.cmux;

import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Open typed union for browser attachment items. */
public sealed interface BrowserAttachmentItem permits
        BrowserAttachmentItem.Snapshot,
        BrowserAttachmentItem.Frame,
        BrowserAttachmentItem.State,
        BrowserAttachmentItem.Unknown {
    String kind();

    record Snapshot(
        Snapshots.BrowserSnapshot browser,
        Snapshots.PixelSize size
    ) implements BrowserAttachmentItem {
        public Snapshot {
            Objects.requireNonNull(browser, "browser");
            Objects.requireNonNull(size, "size");
        }

        @Override
        public String kind() {
            return "snapshot";
        }
    }

    /** Pixels plus their exact pointer token, empty when input is blocked. */
    record Frame(
        String mimeType,
        byte[] data,
        long widthPx,
        long heightPx,
        Optional<Decimal> pointerFrameSeq
    ) implements BrowserAttachmentItem {
        public Frame {
            if (!List.of("image/png", "image/jpeg").contains(mimeType)) {
                throw new IllegalArgumentException("unsupported frame mimeType");
            }
            data = Arrays.copyOf(data, data.length);
            positiveUint32(widthPx, "widthPx");
            positiveUint32(heightPx, "heightPx");
            pointerFrameSeq = pointerFrameSeq == null
                ? Optional.empty()
                : pointerFrameSeq;
        }

        @Override
        public byte[] data() {
            return Arrays.copyOf(data, data.length);
        }

        @Override
        public String kind() {
            return "frame";
        }
    }

    record State(String url, String title, boolean loading)
            implements BrowserAttachmentItem {
        public State {
            Objects.requireNonNull(url, "url");
            Objects.requireNonNull(title, "title");
        }

        @Override
        public String kind() {
            return "state";
        }
    }

    record Unknown(String kind, Map<String, Object> raw)
            implements BrowserAttachmentItem {
        public Unknown {
            Objects.requireNonNull(kind, "kind");
            if (kind.isEmpty() ||
                    List.of("snapshot", "frame", "state").contains(kind)) {
                throw new IllegalArgumentException(
                    "unknown item requires an unrecognized non-empty kind"
                );
            }
            raw = JsonValue.immutableObject(raw, "unknown browser attachment");
        }
    }

    private static void positiveUint32(long value, String name) {
        if (value <= 0 || value > 0xffff_ffffL) {
            throw new IllegalArgumentException(
                name + " must be positive and fit uint32"
            );
        }
    }
}
