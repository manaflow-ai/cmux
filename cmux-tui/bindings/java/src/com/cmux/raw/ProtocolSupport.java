// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.Objects;

final class ProtocolSupport {
    private ProtocolSupport() {}
    static <T> T literal(Object actual, T expected, String context) {
        boolean equal = Objects.equals(actual, expected);
        if (!equal && actual instanceof Number a && expected instanceof Number e) {
            equal = new BigDecimal(a.toString()).compareTo(new BigDecimal(e.toString())) == 0;
        }
        if (!equal) throw new CmuxDecodeException(context + " must equal " + expected, null);
        return expected;
    }
}
