import Foundation

extension ControlCommandCoordinator {
    nonisolated func simulatorUIAction(
        method: String,
        params: [String: JSONValue]
    ) -> ControlSimulatorUIAction? {
        switch method {
        case "simulator.tap":
            guard let elementRef = simulatorUIElementRef(params, "element_ref") else {
                return nil
            }
            guard let preDelay = simulatorUIMilliseconds(
                params, "pre_delay_milliseconds", defaultValue: 0, maximum: 10_000
            ), let postDelay = simulatorUIMilliseconds(
                params, "post_delay_milliseconds", defaultValue: 0, maximum: 10_000
            ) else {
                return nil
            }
            return .tap(
                elementRef: elementRef,
                preDelayMilliseconds: preDelay,
                postDelayMilliseconds: postDelay
            )
        case "simulator.touch":
            guard let elementRef = simulatorUIElementRef(params, "element_ref"),
                  let down = simulatorBool(params, "down"),
                  let up = simulatorBool(params, "up"),
                  down || up,
                  let delay = simulatorUIMilliseconds(
                      params, "delay_milliseconds", defaultValue: 0, maximum: 10_000
                  ),
                  delay == 0 || (down && up) else {
                return nil
            }
            return .touch(
                elementRef: elementRef,
                down: down,
                up: up,
                delayMilliseconds: delay
            )
        case "simulator.swipe", "simulator.drag":
            let refKey = method == "simulator.swipe" ? "within_element_ref" : "element_ref"
            guard let elementRef = simulatorUIElementRef(params, refKey),
                  let direction = simulatorUIDirection(params),
                  let duration = simulatorUIMilliseconds(
                      params, "duration_milliseconds", defaultValue: 300, maximum: 10_000
                  ), duration > 0,
                  let distance = simulatorUIDistance(
                      params, defaultValue: method == "simulator.swipe" ? 1 : 0.35
                  ),
                  let steps = simulatorUIInteger(
                      params, "steps", defaultValue: 16, range: 1...1_000
                  ),
                  let preDelay = simulatorUIMilliseconds(
                      params, "pre_delay_milliseconds", defaultValue: 0, maximum: 10_000
                  ),
                  let postDelay = simulatorUIMilliseconds(
                      params, "post_delay_milliseconds", defaultValue: 0, maximum: 10_000
                  ) else {
                return nil
            }
            if method == "simulator.swipe" {
                return .swipe(
                    elementRef: elementRef,
                    direction: direction,
                    durationMilliseconds: duration,
                    distance: distance,
                    steps: steps,
                    preDelayMilliseconds: preDelay,
                    postDelayMilliseconds: postDelay
                )
            }
            return .drag(
                elementRef: elementRef,
                direction: direction,
                durationMilliseconds: duration,
                distance: distance,
                steps: steps,
                preDelayMilliseconds: preDelay,
                postDelayMilliseconds: postDelay
            )
        case "simulator.long_press":
            guard let elementRef = simulatorUIElementRef(params, "element_ref"),
                  let duration = simulatorUIMilliseconds(
                      params, "duration_milliseconds", maximum: 10_000
                  ), duration > 0 else {
                return nil
            }
            return .longPress(
                elementRef: elementRef,
                durationMilliseconds: duration
            )
        case "simulator.type_text":
            guard let elementRef = simulatorUIElementRef(params, "element_ref"),
                  let text = simulatorUIString(params, "text", maximumBytes: 4_096),
                  let replaceExisting = simulatorBool(params, "replace_existing") else {
                return nil
            }
            return .typeText(
                elementRef: elementRef,
                text: text,
                replaceExisting: replaceExisting
            )
        case "simulator.key_press":
            guard let keyCode = simulatorUIInteger(
                params, "key_code", range: 0...255
            ), let duration = simulatorUIMilliseconds(
                params, "duration_milliseconds", defaultValue: 50, maximum: 10_000
            ) else {
                return nil
            }
            return .keyPress(
                keyCode: UInt32(keyCode),
                durationMilliseconds: duration
            )
        case "simulator.key_sequence":
            guard case let .array(values)? = params["key_codes"],
                  !values.isEmpty, values.count <= 100 else {
                return nil
            }
            let keyCodes = values.compactMap { value -> UInt32? in
                guard case let .int(raw) = value,
                      let integer = Int(exactly: raw),
                      (0...255).contains(integer) else {
                    return nil
                }
                return UInt32(integer)
            }
            guard keyCodes.count == values.count,
                  let delay = simulatorUIMilliseconds(
                      params, "delay_milliseconds", defaultValue: 0, maximum: 5_000
                  ) else {
                return nil
            }
            return .keySequence(
                keyCodes: keyCodes,
                delayMilliseconds: delay
            )
        case "simulator.button":
            guard let button = string(params, "button") else { return nil }
            let duration: Int?
            if params["duration_milliseconds"] == nil {
                duration = nil
            } else {
                duration = simulatorUIMilliseconds(
                    params, "duration_milliseconds", maximum: 10_000
                )
                guard duration != nil else { return nil }
            }
            return .button(
                button: simulatorButtonName(button),
                durationMilliseconds: duration
            )
        case "simulator.gesture_preset":
            guard let preset = simulatorToken(params, "preset"),
                  [
                      "scroll-up", "scroll-down", "scroll-left", "scroll-right",
                      "swipe-from-left-edge", "swipe-from-right-edge",
                      "swipe-from-top-edge", "swipe-from-bottom-edge",
                  ].contains(preset),
                  let duration = simulatorUIMilliseconds(
                      params, "duration_milliseconds", defaultValue: 300, maximum: 10_000
                  ),
                  let distance = simulatorUIDistance(params, defaultValue: 0.6),
                  let steps = simulatorUIInteger(
                      params, "steps", defaultValue: 16, range: 2...256
                  ),
                  let preDelay = simulatorUIMilliseconds(
                      params, "pre_delay_milliseconds", defaultValue: 0, maximum: 10_000
                  ),
                  let postDelay = simulatorUIMilliseconds(
                      params, "post_delay_milliseconds", defaultValue: 0, maximum: 10_000
                  ) else {
                return nil
            }
            return .gesturePreset(
                preset: preset,
                durationMilliseconds: duration,
                distance: distance,
                steps: steps,
                preDelayMilliseconds: preDelay,
                postDelayMilliseconds: postDelay
            )
        case "simulator.batch":
            guard case let .array(rawSteps)? = params["steps"],
                  !rawSteps.isEmpty, rawSteps.count <= 100 else {
                return nil
            }
            var steps: [ControlSimulatorUITapStep] = []
            steps.reserveCapacity(rawSteps.count)
            for rawStep in rawSteps {
                guard case let .object(fields) = rawStep,
                      string(fields, "action") == "tap",
                      let ref = simulatorUIElementRef(fields, "element_ref"),
                      let preDelay = simulatorUIMilliseconds(
                          fields, "pre_delay_milliseconds",
                          defaultValue: 0, maximum: 10_000
                      ),
                      let postDelay = simulatorUIMilliseconds(
                          fields, "post_delay_milliseconds",
                          defaultValue: 0, maximum: 10_000
                      ) else {
                    return nil
                }
                steps.append(ControlSimulatorUITapStep(
                    elementRef: ref,
                    preDelayMilliseconds: preDelay,
                    postDelayMilliseconds: postDelay
                ))
            }
            return .batch(steps: steps)
        default:
            return nil
        }
    }

    nonisolated func simulatorUIWait(
        _ params: [String: JSONValue]
    ) -> ControlSimulatorUIWait? {
        guard let rawPredicate = string(params, "predicate") else {
            return nil
        }
        let predicate = switch rawPredicate {
        case "textContains", "text_contains": "text-contains"
        default: rawPredicate
        }
        guard simulatorToken(["predicate": .string(predicate)], "predicate") != nil,
              ["exists", "gone", "enabled", "focused", "text-contains", "settled"]
                .contains(predicate),
              let timeout = simulatorUIInteger(
                  params, "timeout_milliseconds", defaultValue: 5_000,
                  range: 0...120_000
              ),
              let pollInterval = simulatorUIInteger(
                  params, "poll_interval_milliseconds", defaultValue: 250,
                  range: 1...10_000
              ),
              let settledDuration = simulatorUIInteger(
                  params, "settled_duration_milliseconds", defaultValue: 500,
                  range: 0...30_000
              ) else {
            return nil
        }
        let elementRef: String?
        if params["element_ref"] == nil {
            elementRef = nil
        } else {
            elementRef = simulatorUIElementRef(params, "element_ref")
            guard elementRef != nil else { return nil }
        }
        let identifier = simulatorUIOptionalString(
            params, "identifier", maximumBytes: 512
        )
        let label = simulatorUIOptionalString(params, "label", maximumBytes: 512)
        let role = simulatorUIOptionalString(params, "role", maximumBytes: 64)
        let value = simulatorUIOptionalString(params, "value", maximumBytes: 512)
        let text = simulatorUIOptionalString(params, "text", maximumBytes: 512)
        guard identifier.isValid, label.isValid, role.isValid,
              value.isValid, text.isValid else {
            return nil
        }
        let hasSelector = elementRef != nil || identifier.value != nil || label.value != nil
            || role.value != nil || value.value != nil
        guard predicate == "settled"
                || predicate == "text-contains"
                || (predicate == "gone" && text.value != nil)
                || hasSelector else {
            return nil
        }
        guard predicate != "text-contains" || text.value != nil else { return nil }
        guard ["text-contains", "gone"].contains(predicate) || text.value == nil else {
            return nil
        }
        return ControlSimulatorUIWait(
            predicate: predicate,
            elementRef: elementRef,
            identifier: identifier.value,
            label: label.value,
            role: role.value,
            value: value.value,
            text: text.value,
            timeoutMilliseconds: timeout,
            pollIntervalMilliseconds: pollInterval,
            settledDurationMilliseconds: settledDuration
        )
    }

    private nonisolated func simulatorUIElementRef(
        _ params: [String: JSONValue],
        _ key: String
    ) -> String? {
        guard let ref = string(params, key),
              ref.utf8.count <= 64,
              ref.first == "e",
              !ref.dropFirst().isEmpty,
              ref.dropFirst().allSatisfy(\.isNumber) else {
            return nil
        }
        return ref
    }

    private nonisolated func simulatorUIDirection(
        _ params: [String: JSONValue]
    ) -> String? {
        guard let direction = simulatorToken(params, "direction"),
              ["up", "down", "left", "right"].contains(direction) else {
            return nil
        }
        return direction
    }

    private nonisolated func simulatorUIDistance(
        _ params: [String: JSONValue],
        defaultValue: Double
    ) -> Double? {
        let value = simulatorDouble(params, "distance") ?? defaultValue
        return value.isFinite && value > 0 && value <= 1 ? value : nil
    }

    private nonisolated func simulatorUIMilliseconds(
        _ params: [String: JSONValue],
        _ key: String,
        defaultValue: Int? = nil,
        maximum: Int
    ) -> Int? {
        guard params[key] != nil else { return defaultValue }
        guard let value = simulatorInt(params, key),
              (0...maximum).contains(value) else {
            return nil
        }
        return value
    }

    private nonisolated func simulatorUIInteger(
        _ params: [String: JSONValue],
        _ key: String,
        defaultValue: Int? = nil,
        range: ClosedRange<Int>
    ) -> Int? {
        guard params[key] != nil else { return defaultValue }
        guard let value = simulatorInt(params, key), range.contains(value) else {
            return nil
        }
        return value
    }

    private nonisolated func simulatorUIString(
        _ params: [String: JSONValue],
        _ key: String,
        maximumBytes: Int
    ) -> String? {
        guard let value = string(params, key),
              !value.isEmpty,
              value.utf8.count <= maximumBytes else {
            return nil
        }
        return value
    }

    private nonisolated func simulatorUIOptionalString(
        _ params: [String: JSONValue],
        _ key: String,
        maximumBytes: Int
    ) -> (value: String?, isValid: Bool) {
        guard params[key] != nil else { return (nil, true) }
        guard let value = simulatorUIString(
            params, key, maximumBytes: maximumBytes
        ) else {
            return (nil, false)
        }
        if key == "text",
           value.allSatisfy(\.isWhitespace) {
            return (nil, false)
        }
        return (value, true)
    }
}
