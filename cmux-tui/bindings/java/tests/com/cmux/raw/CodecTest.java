package com.cmux.raw;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class CodecTest {
    public static void main(String[] args) {
        roundTripsLosslessNumbers();
        enforcesJsonDepth();
        rejectsMalformedJson();
        preservesImmutableValues();
    }

    @SuppressWarnings("unchecked")
    private static void roundTripsLosslessNumbers() {
        String maximum = "18446744073709551615";
        Map<String, Object> parsed = (Map<String, Object>) Json.parse(
            "{\"id\":" + maximum + ",\"fraction\":1.2500}"
        );
        check(parsed.get("id").equals(new BigInteger(maximum)), "uint64 JSON precision");
        check(parsed.get("fraction").equals(new BigDecimal("1.2500")), "decimal JSON precision");
        UInt64 unsigned = Wire.uint64(parsed.get("id"), "id");
        check(unsigned.equals(UInt64.MAX_VALUE), "uint64 maximum decode");
        check(Json.stringify(Map.of("id", unsigned)).equals("{\"id\":" + maximum + "}"), "uint64 encode");
        check(UInt64.fromUnsignedLong(-1).equals(UInt64.MAX_VALUE), "unsigned long bit conversion");
        rejects(() -> UInt64.parse("18446744073709551616"), "uint64 overflow");
        rejects(() -> UInt64.of(-1), "negative uint64");
    }

    private static void enforcesJsonDepth() {
        check(Json.parse("[[0]]", 2) instanceof List<?>, "depth boundary");
        rejects(() -> Json.parse("[[[0]]]", 2), "parse depth limit");
        rejects(() -> Json.stringify(List.of(List.of(List.of(0))), 2), "encode depth limit");
    }

    private static void rejectsMalformedJson() {
        rejects(() -> Json.parse("{\"x\":1,\"x\":2}"), "duplicate key");
        rejects(() -> Json.parse("[1,]"), "trailing comma");
        rejects(() -> Json.parse("\"\\uD800\""), "unpaired surrogate");
        rejects(() -> Json.stringify("\uD800"), "unpaired Java surrogate");
        rejects(() -> Json.parse(new byte[] {(byte) 0xc3, 0x28}, 8), "invalid UTF-8");
        rejects(() -> Json.stringify(Double.NaN), "non-finite number");
    }

    private static void preservesImmutableValues() {
        byte[] source = {1, 2, 3};
        Bytes bytes = Bytes.of(source);
        source[0] = 9;
        check(bytes.toByteArray()[0] == 1, "Bytes input copy");
        byte[] copy = bytes.toByteArray();
        copy[1] = 9;
        check(bytes.toByteArray()[1] == 2, "Bytes output copy");

        LinkedHashMap<String, Object> mutable = new LinkedHashMap<>();
        mutable.put("items", List.of(1L, "two"));
        @SuppressWarnings("unchecked")
        Map<String, Object> immutable = (Map<String, Object>) Wire.immutableJson(mutable);
        mutable.put("later", true);
        check(!immutable.containsKey("later"), "immutable JSON copy");

        Field<String> omitted = Field.omitted();
        Field<String> explicitNull = Field.ofNullable(null);
        check(!omitted.isPresent(), "omitted field");
        check(explicitNull.isPresent() && explicitNull.isNull(), "explicit null field");
    }

    private static void rejects(Runnable action, String message) {
        try {
            action.run();
            throw new AssertionError("accepted " + message);
        } catch (JsonException | IllegalArgumentException expected) {
            // expected
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
