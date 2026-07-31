package com.cmux.raw;

public enum CmuxErrorDelivery {
    KNOWN_NOT_DELIVERED,
    AMBIGUOUS;

    static CmuxErrorDelivery fromWire(Object value) {
        if ("known-not-delivered".equals(value)) {
            return KNOWN_NOT_DELIVERED;
        }
        if ("ambiguous".equals(value)) {
            return AMBIGUOUS;
        }
        return null;
    }
}
