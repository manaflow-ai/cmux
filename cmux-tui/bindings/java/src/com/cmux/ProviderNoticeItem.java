package com.cmux;

import java.util.Map;
import java.util.Objects;

/** Open typed union for provider notice stream items. */
public sealed interface ProviderNoticeItem permits
        ProviderNoticeItem.Known, ProviderNoticeItem.Unknown {
    String kind();

    record Known(ProviderNotice notice, Decimal sequence)
            implements ProviderNoticeItem {
        public Known {
            Objects.requireNonNull(notice, "notice");
            Objects.requireNonNull(sequence, "sequence");
        }

        @Override
        public String kind() {
            return "notice";
        }
    }

    record Unknown(String kind, Map<String, Object> raw)
            implements ProviderNoticeItem {
        public Unknown {
            Objects.requireNonNull(kind, "kind");
            if (kind.isEmpty() || kind.equals("notice")) {
                throw new IllegalArgumentException(
                    "unknown notice requires an unrecognized non-empty kind"
                );
            }
            raw = JsonValue.immutableObject(raw, "unknown provider notice");
        }
    }
}
