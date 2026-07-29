package com.cmux;

import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Known notice delivery or a preserved future provider-notice stream variant. */
public record ProviderNoticeItem(
    String kind,
    Optional<ProviderNotice> notice,
    Optional<Decimal> sequence,
    Map<String, Object> raw
) {
    public ProviderNoticeItem {
        Objects.requireNonNull(kind, "kind");
        notice = notice == null ? Optional.empty() : notice;
        sequence = sequence == null ? Optional.empty() : sequence;
        raw = raw == null ? Map.of() : Map.copyOf(raw);
        if (kind.equals("notice") &&
                (notice.isEmpty() || sequence.isEmpty() || !raw.isEmpty())) {
            throw new IllegalArgumentException(
                "known provider notice requires notice and sequence only"
            );
        }
        if (!kind.equals("notice") &&
                (notice.isPresent() || sequence.isPresent())) {
            throw new IllegalArgumentException(
                "unknown provider notice variants preserve only raw data"
            );
        }
    }
}
