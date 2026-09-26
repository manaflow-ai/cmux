import Foundation

/// Structured model outputs contain hypotheses, never execution or repair receipts.
struct ReviewResponseSchema {
    private let text: [String: Any] = ["type": "string"]

    var discovery: [String: Any] {
        object([
            "behavior_changed": array(text),
            "findings": array(object([
                "title": text,
                "severity": ["type": "string", "enum": ["P0", "P1", "P2", "P3"]],
                "claim": text, "failure_mode": text, "paths": array(text)
            ]))
        ])
    }

    var challenge: [String: Any] {
        object([
            "disposition": ["type": "string", "enum": ["refuted", "survives_challenge", "uncertain"]],
            "reason": text
        ])
    }

    private func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }

    private func array(_ items: [String: Any]) -> [String: Any] {
        ["type": "array", "items": items]
    }
}
