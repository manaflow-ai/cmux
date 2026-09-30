package com.cmux;

import com.cmux.internal.Wire;
import com.cmux.raw.Json;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Internal codec and structural validation for generic journal producers. */
final class JournalWire {
    private static final int MAX_MANIFEST_BYTES = 1_048_576;

    private JournalWire() {}

    static Map<String, Object> manifest(JournalProducerManifest value) {
        validate(value);
        return manifestFields(value);
    }

    private static Map<String, Object> manifestFields(JournalProducerManifest value) {
        Map<String, Object> result = Wire.map();
        result.put("producer_id", value.producerId());
        result.put("namespace", value.namespace());
        result.put("manifest_version", value.manifestVersion());
        result.put("max_sensitivity", value.maxSensitivity().name().toLowerCase(java.util.Locale.ROOT));
        result.put("permissions", value.permissions());
        result.put("events", value.events().stream().map(JournalWire::eventSchema).toList());
        return result;
    }

    static Map<String, Object> ingress(JournalIngress value) {
        validate(value);
        Map<String, Object> result = Wire.map();
        result.put("producer_id", value.producerId());
        result.put("manifest_version", value.manifestVersion());
        result.put("kind", value.kind());
        result.put("schema_version", value.schemaVersion());
        value.occurredAtMs().ifPresent(item -> result.put("occurred_at_ms", item));
        if (!value.subjects().isEmpty()) {
            result.put("subjects", value.subjects().stream().map(subject -> Map.of(
                "kind", subject.kind(), "id", subject.id()
            )).toList());
        }
        value.sensitivity().ifPresent(item -> result.put(
            "sensitivity", item.name().toLowerCase(java.util.Locale.ROOT)
        ));
        result.put("payload", value.payload().value());
        value.causationId().ifPresent(item -> result.put("causation_id", item));
        value.correlationId().ifPresent(item -> result.put("correlation_id", item));
        return result;
    }

    private static Map<String, Object> eventSchema(JournalEventSchema value) {
        Map<String, Object> result = Wire.map();
        result.put("kind", value.kind());
        result.put("schema_version", value.schemaVersion());
        result.put("class", value.journalClass().name().toLowerCase(java.util.Locale.ROOT));
        result.put("replay", value.replay().name().toLowerCase(java.util.Locale.ROOT));
        result.put("sensitivity", value.sensitivity().name().toLowerCase(java.util.Locale.ROOT));
        result.put("payload_schema", value.payloadSchema().value());
        return result;
    }

    static JournalProducerManifest decodeManifest(Object value) {
        Map<String, Object> fields = Wire.object(value, "journal producer manifest");
        Client.requireExactFields(fields, "journal producer manifest",
            "producer_id", "namespace", "manifest_version", "max_sensitivity",
            "permissions", "events");
        JournalProducerManifest result = new JournalProducerManifest(
            Wire.string(fields.get("producer_id"), "journal producer id"),
            Wire.string(fields.get("namespace"), "journal producer namespace"),
            positiveUint32(fields.get("manifest_version"), "manifest_version"),
            sensitivity(fields.get("max_sensitivity"), "max_sensitivity"),
            strings(fields.get("permissions"), "permissions"),
            Wire.array(fields.get("events"), "events").stream()
                .map(JournalWire::decodeEventSchema).toList()
        );
        validate(result);
        return result;
    }

    private static JournalEventSchema decodeEventSchema(Object value) {
        Map<String, Object> fields = Wire.object(value, "journal event schema");
        Client.requireExactFields(fields, "journal event schema",
            "kind", "schema_version", "class", "replay", "sensitivity", "payload_schema");
        return new JournalEventSchema(
            Wire.string(fields.get("kind"), "journal event kind"),
            positiveUint32(fields.get("schema_version"), "schema_version"),
            journalClass(fields.get("class")),
            replay(fields.get("replay")),
            sensitivity(fields.get("sensitivity"), "sensitivity"),
            JsonValue.of(fields.get("payload_schema"))
        );
    }

    static JournalProducerListResult decodeList(Object value) {
        Map<String, Object> fields = Wire.object(value, "journal producer list result");
        Client.requireExactFields(fields, "journal producer list result", "producers");
        List<Object> producers = Wire.array(fields.get("producers"), "producers");
        if (producers.size() > 1024) {
            throw new IllegalArgumentException("journal producer list contains too many entries");
        }
        return new JournalProducerListResult(
            producers.stream()
                .map(JournalWire::decodeManifest).toList()
        );
    }

    static JournalProducerPutResult decodePut(Object value) {
        Map<String, Object> fields = Wire.object(value, "journal producer put result");
        Client.requireExactFields(fields, "journal producer put result",
            "producer_id", "manifest_version", "namespace", "sequence", "event_id");
        String producerId = boundedString(fields.get("producer_id"), "producer_id", 1, 64);
        if (!component(producerId)) {
            throw new IllegalArgumentException("producer_id must match the lowercase component grammar");
        }
        String namespace = boundedString(fields.get("namespace"), "namespace", 1, 128);
        if (!namespace.equals("plugin." + producerId)) {
            throw new IllegalArgumentException("namespace must equal plugin.<producer_id>");
        }
        String eventId = boundedString(fields.get("event_id"), "event_id", 1, 128);
        return new JournalProducerPutResult(
            producerId,
            positiveUint32(fields.get("manifest_version"), "manifest_version"),
            namespace,
            Wire.decimal(fields.get("sequence"), "sequence"),
            eventId
        );
    }

    static JournalAppendResult decodeAppend(Object value) {
        Map<String, Object> fields = Wire.object(value, "journal append result");
        Client.requireExactFields(fields, "journal append result",
            "producer_id", "sequence", "event_id");
        String producerId = boundedString(fields.get("producer_id"), "producer_id", 1, 64);
        if (!component(producerId)) {
            throw new IllegalArgumentException("producer_id must match the lowercase component grammar");
        }
        String eventId = boundedString(fields.get("event_id"), "event_id", 1, 128);
        return new JournalAppendResult(
            producerId,
            Wire.decimal(fields.get("sequence"), "sequence"),
            eventId
        );
    }

    static void validate(JournalProducerManifest value) {
        if (!component(value.producerId()) ||
                !value.namespace().equals("plugin." + value.producerId()) ||
                !uint32Positive(value.manifestVersion()) || value.events().isEmpty() ||
                value.events().size() > 64 ||
                value.maxSensitivity() == SessionJournalRecord.Sensitivity.SECRET) {
            throw new IllegalArgumentException("journal producer manifest is invalid");
        }
        if (value.permissions().size() > 32 || value.permissions().isEmpty() ||
                value.permissions().stream().anyMatch(item -> !bounded(item, 1, 128)) ||
                !value.permissions().contains("journal.append." + value.namespace())) {
            throw new IllegalArgumentException("journal producer append permission is required");
        }
        Set<String> identities = new HashSet<>();
        for (JournalEventSchema event : value.events()) {
            if (!kind(event.kind()) || !event.kind().startsWith(value.namespace() + ".") ||
                    event.schemaVersion() <= 0 || event.schemaVersion() > 0xffff_ffffL ||
                    event.sensitivity() == SessionJournalRecord.Sensitivity.SECRET ||
                    rank(event.sensitivity()) > rank(value.maxSensitivity()) ||
                    !identities.add(event.kind() + "\u0000" + event.schemaVersion())) {
                throw new IllegalArgumentException("journal event schema is invalid");
            }
        }
        int encodedBytes = Json.stringify(Wire.encode(manifestFields(value)))
            .getBytes(StandardCharsets.UTF_8).length;
        if (encodedBytes < 1 || encodedBytes > MAX_MANIFEST_BYTES) {
            throw new IllegalArgumentException("journal producer manifest exceeds 1 MiB");
        }
    }

    static void validate(JournalIngress value) {
        if (!component(value.producerId()) || !uint32Positive(value.manifestVersion()) ||
                !uint32Positive(value.schemaVersion()) || !kind(value.kind()) ||
                !value.kind().startsWith("plugin." + value.producerId() + ".") ||
                value.sensitivity().orElse(null) == SessionJournalRecord.Sensitivity.SECRET) {
            throw new IllegalArgumentException("journal event envelope is invalid");
        }
        if (value.subjects().size() > 64) {
            throw new IllegalArgumentException("journal event has too many subjects");
        }
        for (SessionJournalRecord.Subject subject : value.subjects()) {
            if (!component(subject.kind()) || !bounded(subject.id(), 1, 512)) {
                throw new IllegalArgumentException("journal event subject is invalid");
            }
        }
        value.occurredAtMs().ifPresent(item -> {
            if (item == null) throw new IllegalArgumentException("occurred_at_ms is invalid");
        });
        value.causationId().ifPresent(item -> {
            if (!bounded(item, 1, 128)) throw new IllegalArgumentException("causation_id is invalid");
        });
        value.correlationId().ifPresent(item -> {
            if (!bounded(item, 1, 128)) throw new IllegalArgumentException("correlation_id is invalid");
        });
    }

    private static boolean component(String value) {
        if (!bounded(value, 1, 64) ||
                !((value.charAt(0) >= 'a' && value.charAt(0) <= 'z') ||
                  (value.charAt(0) >= '0' && value.charAt(0) <= '9'))) return false;
        for (int index = 0; index < value.length(); index++) {
            char item = value.charAt(index);
            if (!((item >= 'a' && item <= 'z') || (item >= '0' && item <= '9') ||
                    item == '_' || item == '-')) return false;
        }
        return true;
    }

    private static boolean kind(String value) {
        if (!bounded(value, 1, 128)) return false;
        String[] parts = value.split("\\.", -1);
        for (String part : parts) if (!component(part)) return false;
        return true;
    }

    private static int rank(SessionJournalRecord.Sensitivity value) {
        return switch (value) {
            case PUBLIC -> 0;
            case METADATA -> 1;
            case SENSITIVE -> 2;
            case SECRET -> 3;
        };
    }

    private static long positiveUint32(Object value, String context) {
        if (!(value instanceof Number number) || !uint32Positive(number.longValue()) ||
                number.doubleValue() != number.longValue()) {
            throw new IllegalArgumentException(context + " must be a positive uint32");
        }
        return number.longValue();
    }

    private static boolean uint32Positive(long value) {
        return value >= 1 && value <= 0xffff_ffffL;
    }

    private static boolean bounded(String value, int minimumBytes, int maximumBytes) {
        if (value == null) return false;
        try {
            ByteBuffer encoded = StandardCharsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(CharBuffer.wrap(value));
            int length = encoded.remaining();
            return length >= minimumBytes && length <= maximumBytes;
        } catch (CharacterCodingException error) {
            return false;
        }
    }

    private static String boundedString(Object value, String context, int minimumBytes, int maximumBytes) {
        String result = Wire.string(value, context);
        if (!bounded(result, minimumBytes, maximumBytes)) {
            throw new IllegalArgumentException(context + " length is outside protocol bounds");
        }
        return result;
    }

    private static List<String> strings(Object value, String context) {
        return Wire.array(value, context).stream().map(item -> Wire.string(item, context + " item")).toList();
    }

    private static SessionJournalRecord.JournalClass journalClass(Object value) {
        return switch (Wire.string(value, "journal class")) {
            case "state" -> SessionJournalRecord.JournalClass.STATE;
            case "observation" -> SessionJournalRecord.JournalClass.OBSERVATION;
            case "effect" -> SessionJournalRecord.JournalClass.EFFECT;
            case "checkpoint" -> SessionJournalRecord.JournalClass.CHECKPOINT;
            default -> throw new IllegalArgumentException("journal class is invalid");
        };
    }

    private static SessionJournalRecord.ReplayPolicy replay(Object value) {
        return switch (Wire.string(value, "journal replay")) {
            case "required" -> SessionJournalRecord.ReplayPolicy.REQUIRED;
            case "advisory" -> SessionJournalRecord.ReplayPolicy.ADVISORY;
            case "never" -> SessionJournalRecord.ReplayPolicy.NEVER;
            default -> throw new IllegalArgumentException("journal replay is invalid");
        };
    }

    private static SessionJournalRecord.Sensitivity sensitivity(Object value, String context) {
        return switch (Wire.string(value, context)) {
            case "public" -> SessionJournalRecord.Sensitivity.PUBLIC;
            case "metadata" -> SessionJournalRecord.Sensitivity.METADATA;
            case "sensitive" -> SessionJournalRecord.Sensitivity.SENSITIVE;
            case "secret" -> SessionJournalRecord.Sensitivity.SECRET;
            default -> throw new IllegalArgumentException(context + " is invalid");
        };
    }
}
