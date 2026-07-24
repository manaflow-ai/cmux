package com.cmux;

import java.util.Map;

public record ClientSurfaceSize(
    long surface,
    Integer cols,
    Integer rows,
    Boolean sizeParticipating
) {
    static ClientSurfaceSize from(Map<String, Object> data) {
        return new ClientSurfaceSize(
            CmuxClient.asLong(data.get("surface")),
            data.get("cols") instanceof Number value ? value.intValue() : null,
            data.get("rows") instanceof Number value ? value.intValue() : null,
            data.get("size_participating") instanceof Boolean value ? value : null
        );
    }
}
