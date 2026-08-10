package com.cmux;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Objects;

/** Exact details returned by the confirmation.required resource error. */
public record ConfirmationRequiredDetails(
    String confirmationToken,
    Decimal revision,
    List<Ids.PaneId> closesPanes
) {
    public ConfirmationRequiredDetails {
        Objects.requireNonNull(confirmationToken, "confirmationToken");
        int tokenBytes = confirmationToken.getBytes(StandardCharsets.UTF_8).length;
        if (tokenBytes < 1 || tokenBytes > 128) {
            throw new IllegalArgumentException(
                "confirmationToken must contain 1 to 128 UTF-8 bytes"
            );
        }
        Objects.requireNonNull(revision, "revision");
        closesPanes = List.copyOf(closesPanes);
        if (closesPanes.isEmpty()) {
            throw new IllegalArgumentException("closesPanes must not be empty");
        }
    }
}
