import CmuxSimulator
import Foundation

extension CMUXCLI {
    func simulatorAgentRequest(
        subcommand: String,
        arguments: SimulatorArguments
    ) throws -> SimulatorAgentRequest? {
        let values = arguments.positionals
        let uiSubcommands: Set<String> = [
            "snapshot", "snapshot-ui", "snapshot_ui",
            "wait", "wait-for-ui", "wait_for_ui",
            "tap", "touch", "drag", "swipe",
            "long-press", "long_press",
            "type", "type-text", "type_text",
            "key", "key-press", "key_press",
            "keys", "key-sequence", "key_sequence",
            "batch", "gesture", "gesture-preset", "gesture_preset", "button",
        ]
        if !uiSubcommands.contains(subcommand) {
            try requireSimulatorUIOptions(arguments, subcommand: subcommand)
        }
        if !["permissions", "wait", "wait-for-ui", "wait_for_ui"].contains(subcommand),
           arguments.optionValue != nil {
            throw simulatorArgumentsError(subcommand)
        }
        if !["tap", "wait", "wait-for-ui", "wait_for_ui"].contains(subcommand),
           arguments.hasAccessibilitySelector {
            throw simulatorArgumentsError(subcommand)
        }
        switch subcommand {
        case "select", "select-device":
            guard let value = oneSimulatorValue(arguments) else {
                throw simulatorArgumentsError(subcommand)
            }
            return request(
                "simulator.select_device",
                ["device_id": value],
                timeout: simulatorOperationDeadlines.clientTimeout(
                    for: simulatorOperationDeadlines.selectDevice
                )
            )
        case "recover":
            try requireNoSimulatorSource(arguments, subcommand: subcommand)
            return request(
                "simulator.recover",
                [:],
                timeout: simulatorOperationDeadlines.clientTimeout(
                    for: simulatorOperationDeadlines.recover
                )
            )
        case "snapshot", "snapshot-ui", "snapshot_ui":
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: ["since-screen-hash"]
            )
            guard values.isEmpty, !arguments.readsStandardInput,
                  arguments.file == nil, !arguments.hasAccessibilitySelector,
                  arguments.elementRef == nil else {
                throw simulatorArgumentsError(subcommand)
            }
            var params: [String: Any] = [:]
            if let hash = arguments.option("since-screen-hash") {
                params["since_screen_hash"] = hash
            }
            return request(
                "simulator.snapshot_ui",
                params,
                timeout: simulatorOperationDeadlines.clientTimeout(
                    for: simulatorOperationDeadlines.inspectionRead
                ),
                output: .uiSnapshot
            )
        case "wait", "wait-for-ui", "wait_for_ui":
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: simulatorUIRefOptionNames.union([
                    "text", "timeout-ms", "poll-interval-ms", "settled-duration-ms",
                ])
            )
            return try simulatorUIWaitRequest(arguments)
        case "tap":
            guard !arguments.readsStandardInput, arguments.file == nil else {
                throw simulatorArgumentsError(subcommand)
            }
            if let elementRef = arguments.elementRef {
                try requireSimulatorUIOptions(
                    arguments,
                    subcommand: subcommand,
                    options: simulatorUIRefOptionNames.union(["pre-delay", "post-delay"])
                )
                guard values.isEmpty, !arguments.hasAccessibilitySelector else {
                    throw simulatorArgumentsError(subcommand)
                }
                var params: [String: Any] = ["element_ref": elementRef]
                params.merge(
                    try simulatorUIDelayParameters(arguments),
                    uniquingKeysWith: { _, new in new }
                )
                return request("simulator.tap", params)
            }
            if arguments.hasAccessibilitySelector {
                try requireSimulatorUIOptions(arguments, subcommand: subcommand)
                guard values.isEmpty,
                      arguments.accessibilityLabel != nil
                        || arguments.accessibilityIdentifier != nil else {
                    throw simulatorArgumentsError(subcommand)
                }
                var params: [String: Any] = [:]
                if let label = arguments.accessibilityLabel { params["label"] = label }
                if let identifier = arguments.accessibilityIdentifier {
                    params["identifier"] = identifier
                }
                if let role = arguments.accessibilityRole { params["role"] = role }
                return request("simulator.tap", params)
            }
            try requireSimulatorUIOptions(arguments, subcommand: subcommand)
            guard values.count == 2 || values.count == 4 else {
                throw simulatorArgumentsError(subcommand)
            }
            let point = try simulatorPoint(values[0], values[1])
            var params: [String: Any] = ["x": point.x, "y": point.y]
            if values.count == 4 {
                let second = try simulatorPoint(values[2], values[3])
                params["x2"] = second.x
                params["y2"] = second.y
            }
            return request("simulator.tap", params)
        case "touch":
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: simulatorUIRefOptionNames.union(["delay"]),
                flags: ["down", "up"]
            )
            guard let elementRef = arguments.elementRef,
                  values.isEmpty,
                  !arguments.readsStandardInput,
                  arguments.file == nil,
                  arguments.hasFlag("down") || arguments.hasFlag("up") else {
                throw simulatorArgumentsError(subcommand)
            }
            let delay = try simulatorUIMilliseconds(
                arguments.option("delay"),
                maximum: 10_000,
                defaultValue: 0
            )
            guard delay == 0
                    || (arguments.hasFlag("down") && arguments.hasFlag("up")) else {
                throw simulatorArgumentsError(subcommand)
            }
            return request("simulator.touch", [
                "element_ref": elementRef,
                "down": arguments.hasFlag("down"),
                "up": arguments.hasFlag("up"),
                "delay_milliseconds": delay,
            ])
        case "drag":
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: simulatorUIRefOptionNames.union([
                    "direction", "duration", "distance", "steps",
                    "pre-delay", "post-delay",
                ])
            )
            return try simulatorUISemanticGestureRequest(
                arguments,
                method: "simulator.drag",
                refKey: "element_ref",
                defaultDistance: 0.35
            )
        case "long-press", "long_press":
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: simulatorUIRefOptionNames.union(["duration-ms"])
            )
            guard let elementRef = arguments.elementRef,
                  !arguments.readsStandardInput, arguments.file == nil else {
                throw simulatorArgumentsError(subcommand)
            }
            let rawDuration = arguments.option("duration-ms") ?? values.first
            guard values.count <= 1, let rawDuration,
                  let duration = Int(rawDuration), (1...10_000).contains(duration) else {
                throw simulatorArgumentsError(subcommand)
            }
            return request("simulator.long_press", [
                "element_ref": elementRef,
                "duration_milliseconds": duration,
            ])
        case "type-text", "type_text":
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: simulatorUIRefOptionNames,
                flags: ["replace-existing"]
            )
            return try simulatorUISemanticTypeRequest(arguments)
        case "type":
            guard arguments.elementRef != nil else {
                try requireSimulatorUIOptions(arguments, subcommand: subcommand)
                return nil
            }
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: simulatorUIRefOptionNames,
                flags: ["replace-existing"]
            )
            return try simulatorUISemanticTypeRequest(arguments)
        case "key", "key-press", "key_press":
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: ["key-code", "duration"]
            )
            guard !arguments.readsStandardInput, arguments.file == nil else {
                throw simulatorArgumentsError(subcommand)
            }
            let rawCode = arguments.option("key-code") ?? values.first
            guard values.count <= 1, let rawCode,
                  let code = Int(rawCode), (0...255).contains(code) else {
                throw simulatorArgumentsError(subcommand)
            }
            let duration = try simulatorUIMilliseconds(
                arguments.option("duration"),
                maximum: 10_000,
                defaultValue: 50
            )
            return request("simulator.key_press", [
                "key_code": code,
                "duration_milliseconds": duration,
            ])
        case "keys", "key-sequence", "key_sequence":
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: ["key-codes", "delay"]
            )
            guard !arguments.readsStandardInput, arguments.file == nil else {
                throw simulatorArgumentsError(subcommand)
            }
            let rawCodes = arguments.option("key-codes") ?? values.first
            guard values.count <= 1, let rawCodes else {
                throw simulatorArgumentsError(subcommand)
            }
            let codes = rawCodes.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !codes.isEmpty, codes.count <= 100,
                  codes.allSatisfy({ (0...255).contains($0) }) else {
                throw simulatorArgumentsError(subcommand)
            }
            let delay = try simulatorUIMilliseconds(
                arguments.option("delay"),
                maximum: 5_000,
                defaultValue: 0
            )
            return request("simulator.key_sequence", [
                "key_codes": codes,
                "delay_milliseconds": delay,
            ])
        case "batch":
            try requireSimulatorUIOptions(arguments, subcommand: subcommand)
            return try simulatorUIBatchRequest(arguments)
        case "gesture-preset", "gesture_preset":
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: ["duration", "distance", "steps", "pre-delay", "post-delay"]
            )
            return try simulatorUIGesturePresetRequest(arguments)
        case "gesture", "multitouch", "multi-touch":
            if subcommand == "gesture",
               let preset = values.first,
               simulatorUIGesturePresets.contains(preset),
               values.count == 1,
               !arguments.readsStandardInput,
               arguments.file == nil {
                try requireSimulatorUIOptions(
                    arguments,
                    subcommand: subcommand,
                    options: ["duration", "distance", "steps", "pre-delay", "post-delay"]
                )
                return try simulatorUIGesturePresetRequest(arguments)
            }
            try requireSimulatorUIOptions(arguments, subcommand: subcommand)
            let source = try simulatorSourceValue(arguments, maximumBytes: 64 * 1_024)
            guard let data = source.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) else {
                throw CLIError(message: String(
                    localized: "cli.simulator.error.invalidGestureJSON",
                    defaultValue: "simulator gesture requires a JSON touch object or array"
                ))
            }
            let events = decoded as? [Any] ?? [decoded]
            guard !events.isEmpty, events.count <= 256,
                  events.allSatisfy({ $0 is [String: Any] }) else {
                throw CLIError(message: String(
                    localized: "cli.simulator.error.invalidGestureJSON",
                    defaultValue: "simulator gesture requires a JSON touch object or array"
                ))
            }
            return request(subcommand == "gesture" ? "simulator.gesture" : "simulator.multi_touch",
                           ["events": events])
        case "swipe":
            if arguments.elementRef != nil {
                try requireSimulatorUIOptions(
                    arguments,
                    subcommand: subcommand,
                    options: simulatorUIRefOptionNames.union([
                        "direction", "duration", "distance", "steps",
                        "pre-delay", "post-delay",
                    ])
                )
                return try simulatorUISemanticGestureRequest(
                    arguments,
                    method: "simulator.swipe",
                    refKey: "within_element_ref",
                    defaultDistance: 1
                )
            }
            try requireSimulatorUIOptions(arguments, subcommand: subcommand)
            guard !arguments.readsStandardInput, arguments.file == nil,
                  [4, 5, 8, 9].contains(values.count) else { throw simulatorArgumentsError(subcommand) }
            let from = try simulatorPoint(values[0], values[1])
            let to = try simulatorPoint(values[2], values[3])
            var params: [String: Any] = [
                "from_x": from.x, "from_y": from.y,
                "to_x": to.x, "to_y": to.y,
            ]
            if values.count >= 8 {
                let secondFrom = try simulatorPoint(values[4], values[5])
                let secondTo = try simulatorPoint(values[6], values[7])
                params["from_x2"] = secondFrom.x
                params["from_y2"] = secondFrom.y
                params["to_x2"] = secondTo.x
                params["to_y2"] = secondTo.y
            }
            if values.count == 5 || values.count == 9 {
                let stepIndex = values.count == 5 ? 4 : 8
                guard let steps = Int(values[stepIndex]), (2...64).contains(steps) else {
                    throw simulatorArgumentsError(subcommand)
                }
                params["steps"] = steps
            }
            return request("simulator.swipe", params)
        case "button":
            try requireSimulatorUIOptions(
                arguments,
                subcommand: subcommand,
                options: ["duration"]
            )
            guard let value = oneSimulatorValue(arguments) else { throw simulatorArgumentsError(subcommand) }
            var params: [String: Any] = ["button": simulatorButtonName(value)]
            if arguments.option("duration") != nil {
                params["duration_milliseconds"] = try simulatorUIMilliseconds(
                    arguments.option("duration"),
                    maximum: 10_000,
                    defaultValue: 0
                )
            }
            return request("simulator.button", params)
        case "rotate":
            guard let value = oneSimulatorValue(arguments) else { throw simulatorArgumentsError(subcommand) }
            return request("simulator.rotate", ["orientation": value.replacingOccurrences(of: "-", with: "_")])
        case "ca":
            guard !arguments.readsStandardInput, arguments.file == nil, values.count == 2,
                  let enabled = simulatorOnOff(values[1]) else { throw simulatorArgumentsError(subcommand) }
            return request("simulator.core_animation", [
                "diagnostic": simulatorCADiagnosticName(values[0]), "enabled": enabled,
            ])
        case "memory-warning", "memory_warning":
            try requireNoSimulatorSource(arguments, subcommand: subcommand)
            return request("simulator.memory_warning", [:])
        case "event-log", "events":
            guard !arguments.readsStandardInput, arguments.file == nil, values.count <= 1 else {
                throw simulatorArgumentsError(subcommand)
            }
            var params: [String: Any] = [:]
            if let raw = values.first {
                guard let limit = Int(raw), (1...500).contains(limit) else {
                    throw simulatorArgumentsError(subcommand)
                }
                params["limit"] = limit
            }
            return request("simulator.event_log", params, output: .eventLog)
        case "tools":
            guard let action = oneSimulatorValue(arguments)?.lowercased(),
                  ["show", "hide", "toggle"].contains(action) else {
                throw simulatorArgumentsError(subcommand)
            }
            return request("simulator.tools", ["action": action])
        case "camera":
            return try simulatorCameraRequest(arguments)
        case "permissions":
            return try simulatorPermissionsRequest(arguments)
        case "ui":
            return try simulatorInterfaceRequest(arguments)
        case "accessibility", "ax":
            try requireNoSimulatorSource(arguments, subcommand: subcommand)
            return request(
                "simulator.accessibility",
                [:],
                output: .accessibility
            )
        case "foreground":
            try requireNoSimulatorSource(arguments, subcommand: subcommand)
            return request(
                "simulator.foreground",
                [:],
                timeout: simulatorOperationDeadlines.clientTimeout(
                    for: simulatorOperationDeadlines.inspectionRead
                ),
                output: .foregroundApplication
            )
        default:
            return nil
        }
    }

    private var simulatorUIGesturePresets: Set<String> {
        [
            "scroll-up", "scroll-down", "scroll-left", "scroll-right",
            "swipe-from-left-edge", "swipe-from-right-edge",
            "swipe-from-top-edge", "swipe-from-bottom-edge",
        ]
    }

    private var simulatorUIRefOptionNames: Set<String> {
        ["ref", "element-ref", "within-element-ref"]
    }

    private var simulatorUIOptionNames: Set<String> {
        simulatorUIRefOptionNames.union([
            "text", "since-screen-hash", "duration", "duration-ms", "distance",
            "delay", "pre-delay", "post-delay", "steps", "timeout-ms",
            "poll-interval-ms", "settled-duration-ms", "key-code", "key-codes",
            "direction",
        ])
    }

    private func requireSimulatorUIOptions(
        _ arguments: SimulatorArguments,
        subcommand: String,
        options allowedOptions: Set<String> = [],
        flags allowedFlags: Set<String> = []
    ) throws {
        let suppliedOptions = Set(arguments.options.keys).intersection(simulatorUIOptionNames)
        let suppliedFlags = arguments.flags.intersection([
            "down", "up", "replace-existing",
        ])
        guard suppliedOptions.isSubset(of: allowedOptions),
              suppliedFlags.isSubset(of: allowedFlags) else {
            throw simulatorArgumentsError(subcommand)
        }
    }

    private func simulatorUIWaitRequest(
        _ arguments: SimulatorArguments
    ) throws -> SimulatorAgentRequest {
        guard !arguments.readsStandardInput, arguments.file == nil,
              arguments.positionals.count == 1 else {
            throw simulatorArgumentsError("wait")
        }
        let predicate = switch arguments.positionals[0].lowercased() {
        case "textcontains", "text_contains", "text-contains": "text-contains"
        case let value: value
        }
        guard ["exists", "gone", "enabled", "focused", "text-contains", "settled"]
            .contains(predicate) else {
            throw simulatorArgumentsError("wait")
        }
        var params: [String: Any] = [
            "predicate": predicate,
            "timeout_milliseconds": try simulatorUIInteger(
                arguments.option("timeout-ms"),
                range: 0...120_000,
                defaultValue: 5_000
            ),
            "poll_interval_milliseconds": try simulatorUIInteger(
                arguments.option("poll-interval-ms"),
                range: 1...10_000,
                defaultValue: 250
            ),
            "settled_duration_milliseconds": try simulatorUIInteger(
                arguments.option("settled-duration-ms"),
                range: 0...30_000,
                defaultValue: 500
            ),
        ]
        if let ref = arguments.elementRef { params["element_ref"] = ref }
        if let identifier = arguments.accessibilityIdentifier {
            params["identifier"] = identifier
        }
        if let label = arguments.accessibilityLabel { params["label"] = label }
        if let role = arguments.accessibilityRole {
            params["role"] = simulatorUIRoleName(role)
        }
        if let value = arguments.optionValue { params["value"] = value }
        if let text = arguments.option("text") { params["text"] = text }
        let hasSelector = arguments.elementRef != nil
            || arguments.accessibilityIdentifier != nil
            || arguments.accessibilityLabel != nil
            || arguments.accessibilityRole != nil
            || arguments.optionValue != nil
        let text = arguments.option("text")
        guard predicate == "settled"
                || predicate == "text-contains"
                || (predicate == "gone" && text != nil)
                || hasSelector,
              predicate != "text-contains"
                || text?.allSatisfy(\.isWhitespace) == false,
              ["text-contains", "gone"].contains(predicate) || text == nil else {
            throw simulatorArgumentsError("wait")
        }
        let timeout = params["timeout_milliseconds"] as? Int ?? 5_000
        return request(
            "simulator.wait_for_ui",
            params,
            timeout: simulatorOperationDeadlines.clientTimeout(
                for: Double(timeout) / 1_000 + 35
            ),
            output: .uiWait
        )
    }

    private func simulatorUISemanticGestureRequest(
        _ arguments: SimulatorArguments,
        method: String,
        refKey: String,
        defaultDistance: Double
    ) throws -> SimulatorAgentRequest {
        guard let elementRef = arguments.elementRef,
              !arguments.readsStandardInput, arguments.file == nil else {
            throw simulatorArgumentsError(method)
        }
        let direction = arguments.option("direction") ?? arguments.positionals.first
        guard arguments.positionals.count <= 1,
              let direction,
              ["up", "down", "left", "right"].contains(direction.lowercased()) else {
            throw simulatorArgumentsError(method)
        }
        let duration = try simulatorUIMilliseconds(
            arguments.option("duration"),
            maximum: 10_000,
            defaultValue: 300
        )
        guard duration > 0 else {
            throw simulatorArgumentsError(method)
        }
        var params: [String: Any] = [
            refKey: elementRef,
            "direction": direction.lowercased(),
            "duration_milliseconds": duration,
            "distance": try simulatorUIDouble(
                arguments.option("distance"),
                range: 0.000_001...1,
                defaultValue: defaultDistance
            ),
            "steps": try simulatorUIInteger(
                arguments.option("steps"),
                range: 1...1_000,
                defaultValue: 16
            ),
        ]
        params.merge(
            try simulatorUIDelayParameters(arguments),
            uniquingKeysWith: { _, new in new }
        )
        return request(method, params)
    }

    private func simulatorUISemanticTypeRequest(
        _ arguments: SimulatorArguments
    ) throws -> SimulatorAgentRequest {
        guard let elementRef = arguments.elementRef else {
            throw simulatorArgumentsError("type")
        }
        let text = try simulatorSourceValue(arguments, maximumBytes: Self.simulatorTextLimit)
        guard !text.isEmpty else {
            throw simulatorArgumentsError("type")
        }
        return request(
            "simulator.type_text",
            [
                "element_ref": elementRef,
                "text": text,
                "replace_existing": arguments.hasFlag("replace-existing"),
            ],
            timeout: simulatorOperationDeadlines.clientTimeout(for: 140)
        )
    }

    private func simulatorUIBatchRequest(
        _ arguments: SimulatorArguments
    ) throws -> SimulatorAgentRequest {
        let source = try simulatorSourceValue(arguments, maximumBytes: 64 * 1_024)
        guard let data = source.data(using: .utf8),
              let rawSteps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !rawSteps.isEmpty, rawSteps.count <= 100 else {
            throw simulatorArgumentsError("batch")
        }
        let steps: [[String: Any]] = try rawSteps.map { step in
            let allowedKeys: Set<String> = [
                "action", "element_ref", "elementRef",
                "pre_delay", "preDelay", "post_delay", "postDelay",
            ]
            guard Set(step.keys).isSubset(of: allowedKeys),
                  (step["action"] as? String) == "tap",
                  let ref = (step["element_ref"] as? String)
                    ?? (step["elementRef"] as? String) else {
                throw simulatorArgumentsError("batch")
            }
            var normalized: [String: Any] = [
                "action": "tap",
                "element_ref": ref,
            ]
            if let rawValue = step["pre_delay"] ?? step["preDelay"] {
                guard let value = simulatorUIBatchNumber(rawValue) else {
                    throw simulatorArgumentsError("batch")
                }
                normalized["pre_delay_milliseconds"] = try simulatorUIMilliseconds(
                    String(value), maximum: 10_000, defaultValue: 0
                )
            }
            if let rawValue = step["post_delay"] ?? step["postDelay"] {
                guard let value = simulatorUIBatchNumber(rawValue) else {
                    throw simulatorArgumentsError("batch")
                }
                normalized["post_delay_milliseconds"] = try simulatorUIMilliseconds(
                    String(value), maximum: 10_000, defaultValue: 0
                )
            }
            return normalized
        }
        return request("simulator.batch", ["steps": steps], timeout: 140)
    }

    private func simulatorUIGesturePresetRequest(
        _ arguments: SimulatorArguments
    ) throws -> SimulatorAgentRequest {
        guard !arguments.readsStandardInput, arguments.file == nil,
              arguments.positionals.count == 1 else {
            throw simulatorArgumentsError("gesture-preset")
        }
        let preset = arguments.positionals[0].lowercased()
        guard simulatorUIGesturePresets.contains(preset) else {
            throw simulatorArgumentsError("gesture-preset")
        }
        var params: [String: Any] = [
            "preset": preset,
            "duration_milliseconds": try simulatorUIMilliseconds(
                arguments.option("duration"),
                maximum: 10_000,
                defaultValue: 300
            ),
            "distance": try simulatorUIDouble(
                arguments.option("distance"),
                range: 0.000_001...1,
                defaultValue: 0.6
            ),
            "steps": try simulatorUIInteger(
                arguments.option("steps"),
                range: 2...256,
                defaultValue: 16
            ),
        ]
        params.merge(
            try simulatorUIDelayParameters(arguments),
            uniquingKeysWith: { _, new in new }
        )
        return request("simulator.gesture_preset", params)
    }

    private func simulatorUIDelayParameters(
        _ arguments: SimulatorArguments
    ) throws -> [String: Any] {
        [
            "pre_delay_milliseconds": try simulatorUIMilliseconds(
                arguments.option("pre-delay"),
                maximum: 10_000,
                defaultValue: 0
            ),
            "post_delay_milliseconds": try simulatorUIMilliseconds(
                arguments.option("post-delay"),
                maximum: 10_000,
                defaultValue: 0
            ),
        ]
    }

    private func simulatorUIMilliseconds(
        _ rawSeconds: String?,
        maximum: Int,
        defaultValue: Int
    ) throws -> Int {
        guard let rawSeconds else { return defaultValue }
        guard let seconds = Double(rawSeconds), seconds.isFinite, seconds >= 0 else {
            throw simulatorArgumentsError("duration")
        }
        let milliseconds = Int((seconds * 1_000).rounded())
        guard milliseconds <= maximum else {
            throw simulatorArgumentsError("duration")
        }
        return milliseconds
    }

    private func simulatorUIInteger(
        _ raw: String?,
        range: ClosedRange<Int>,
        defaultValue: Int
    ) throws -> Int {
        guard let raw else { return defaultValue }
        guard let value = Int(raw), range.contains(value) else {
            throw simulatorArgumentsError("number")
        }
        return value
    }

    private func simulatorUIDouble(
        _ raw: String?,
        range: ClosedRange<Double>,
        defaultValue: Double
    ) throws -> Double {
        guard let raw else { return defaultValue }
        guard let value = Double(raw), value.isFinite, range.contains(value) else {
            throw simulatorArgumentsError("number")
        }
        return value
    }

    private func simulatorUIBatchNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.doubleValue
    }

    private func simulatorUIRoleName(_ raw: String) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return switch normalized {
        case "keyboardkey": "keyboard-key"
        case "scrollview": "scroll-view"
        case "textfield": "text-field"
        default: normalized
        }
    }

    func simulatorCameraRequest(_ arguments: SimulatorArguments) throws -> SimulatorAgentRequest {
        guard !arguments.readsStandardInput, arguments.file == nil,
              let action = arguments.positionals.first?.lowercased() else {
            throw simulatorArgumentsError("camera")
        }
        let values = Array(arguments.positionals.dropFirst())
        switch action {
        case "configure":
            guard !values.isEmpty else { throw simulatorArgumentsError("camera configure") }
            let source = values.count >= 2 ? values[1] : "placeholder"
            let sourceArguments = values.count >= 2 ? Array(values.dropFirst(2)) : []
            var params = try simulatorCameraSourceParams(sourceArguments, source: source)
            params["bundle_id"] = values[0]
            return request(
                "simulator.camera.configure",
                params,
                timeout: simulatorOperationDeadlines.clientTimeout(for: 160),
                output: .cameraStatus
            )
        case "switch":
            guard let source = values.first,
                  !["off", "disabled"].contains(source.lowercased()) else {
                throw simulatorArgumentsError("camera switch")
            }
            return request(
                "simulator.camera.switch",
                try simulatorCameraSourceParams(Array(values.dropFirst()), source: source),
                timeout: simulatorOperationDeadlines.clientTimeout(for: 160),
                output: .cameraStatus
            )
        case "mirror":
            guard values.count == 1, ["auto", "on", "off"].contains(values[0]) else {
                throw simulatorArgumentsError("camera mirror")
            }
            return request("simulator.camera.mirror", ["mode": values[0]], output: .cameraStatus)
        case "status", "webcams":
            guard values.isEmpty else { throw simulatorArgumentsError("camera \(action)") }
            return request("simulator.camera.status", [:], output: .cameraStatus)
        case "stop":
            guard values.isEmpty else { throw simulatorArgumentsError("camera stop") }
            return request(
                "simulator.camera.configure",
                ["source": "off"],
                timeout: simulatorOperationDeadlines.clientTimeout(for: 160),
                output: .cameraStatus
            )
        default:
            throw simulatorArgumentsError("camera")
        }
    }

    func simulatorCameraSourceParams(
        _ arguments: [String], source rawSource: String
    ) throws -> [String: Any] {
        let source = rawSource.lowercased()
        guard ["off", "placeholder", "image", "file", "video", "host", "webcam"].contains(source) else {
            throw simulatorArgumentsError("camera")
        }
        var values = arguments
        var params: [String: Any] = ["source": source]
        if ["image", "file", "video"].contains(source) {
            guard !values.isEmpty else { throw simulatorArgumentsError("camera") }
            let rawPath = values.removeFirst()
            params["path"] = URL(
                fileURLWithPath: rawPath,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            ).standardizedFileURL.path
            if ["file", "video"].contains(source) { params["loops"] = true }
        } else if ["host", "webcam"].contains(source), !values.isEmpty {
            params["device_id"] = values.removeFirst()
        }
        if values.first?.lowercased() == "loop" {
            params["loops"] = true
            values.removeFirst()
        }
        guard values.isEmpty else { throw simulatorArgumentsError("camera") }
        return params
    }

    func request(
        _ method: String,
        _ params: [String: Any],
        timeout: TimeInterval? = simulatorOperationDeadlines.clientTimeout(for: 35),
        output: SimulatorAgentOutput = .completed
    ) -> SimulatorAgentRequest {
        SimulatorAgentRequest(method: method, params: params, timeout: timeout, output: output)
    }
}
