package com.cmux;

import java.util.List;

/** Installed generic journal producer manifests. */
public record JournalProducerListResult(List<JournalProducerManifest> producers) {
    public JournalProducerListResult {
        producers = producers == null ? List.of() : List.copyOf(producers);
        if (producers.size() > 1024) {
            throw new IllegalArgumentException("journal producer list contains too many entries");
        }
    }
}
