import Foundation

/// JavaScript evaluation wrapping and bridge-safe result handling.
extension BrowserControlService {
    /// Builds the complete function body used to evaluate browser JavaScript.
    ///
    /// The wrapper awaits promise-like results, converts DOM rectangles and
    /// JSON containers before they cross WebKit, duplicates repeated aliases,
    /// and emits deterministic error envelopes for cycles or results whose
    /// normalization would exceed bounded work.
    ///
    /// - Parameters:
    ///   - script: User or automation JavaScript to execute.
    ///   - useEval: Whether `script` is data passed to `eval`; when false it is
    ///     inserted as a trusted expression built by cmux.
    ///   - frameSelector: Optional selector for a same-origin frame execution realm.
    /// - Returns: A JavaScript async-function body for WebKit evaluation.
    public func evaluationScript(
        script: String,
        useEval: Bool,
        frameSelector: String?
    ) -> String {
        let typeKey = jsonLiteral(evalEnvelope.typeKey)
        let valueKey = jsonLiteral(evalEnvelope.valueKey)
        let typeUndefined = jsonLiteral(evalEnvelope.typeUndefined)
        let typeValue = jsonLiteral(evalEnvelope.typeValue)
        let typeError = jsonLiteral(evalEnvelope.typeError)
        let errorCodeKey = jsonLiteral(evalEnvelope.errorCodeKey)
        let errorMessageKey = jsonLiteral(evalEnvelope.errorMessageKey)
        let frameUnavailableCode = jsonLiteral("frame_unavailable")
        let operationFailedMessage = jsonLiteral(String(
            localized: "cli.browser.error.operationFailed",
            defaultValue: "Browser operation failed"
        ))

        let framePrelude: String
        if let frameSelector {
            let selectorLiteral = jsonLiteral(frameSelector)
            framePrelude = """
            let __cmuxDoc;
            let __cmuxWindow;
            const __cmuxFrameUnavailable = () => ({
              [\(typeKey)]: \(typeError),
              [\(errorCodeKey)]: \(frameUnavailableCode),
              [\(errorMessageKey)]: \(operationFailedMessage)
            });
            try {
              const __cmuxFrame = document.querySelector(\(selectorLiteral));
              if (!__cmuxFrame || !('contentDocument' in __cmuxFrame)) {
                return __cmuxFrameUnavailable();
              }
              const __cmuxFrameDocument = __cmuxFrame.contentDocument;
              const __cmuxFrameWindow = __cmuxFrame.contentWindow;
              if (!__cmuxFrameDocument || !__cmuxFrameWindow) {
                return __cmuxFrameUnavailable();
              }
              __cmuxDoc = __cmuxFrameDocument;
              __cmuxWindow = __cmuxFrameWindow;
            } catch (_) {
              return __cmuxFrameUnavailable();
            }
            """
        } else {
            framePrelude = "const __cmuxDoc = document;"
        }

        let executionBlock: String
        if frameSelector != nil {
            // Member-call eval is indirect. The eval function belongs to the
            // selected frame, so every global lookup uses that frame's realm.
            executionBlock = "const __r = __cmuxWindow.eval(\(jsonLiteral(script)));"
        } else {
            executionBlock = useEval
                ? "const __r = eval(\(jsonLiteral(script)));"
                : "const __r = \(script);"
        }
        let circularReferenceCode = jsonLiteral(evalEnvelope.circularReferenceCode)
        let circularReferenceMessage = jsonLiteral(evalEnvelope.circularReferenceMessage)
        let resultTooComplexCode = jsonLiteral("result_too_complex")

        return """
        \(framePrelude)

        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __cmuxCircularReference = Symbol('cmux.circularReference');
        const __cmuxResultTooComplex = Symbol('cmux.resultTooComplex');
        const __cmuxChargeText = (__text, __budget) => {
          if (__text.length > __budget.remainingTextCodeUnits) {
            throw __cmuxResultTooComplex;
          }
          __budget.remainingTextCodeUnits -= __text.length;
        };
        const __cmuxBridgeSafeValue = (
          __value,
          __ancestors = new WeakSet(),
          __budget = {remainingNodes: 10000, remainingTextCodeUnits: 1000000},
          __depth = 0
        ) => {
          if (__budget.remainingNodes <= 0 || __depth > 100) {
            throw __cmuxResultTooComplex;
          }
          __budget.remainingNodes -= 1;

          if (__value === null) {
            return null;
          }
          if (typeof __value === 'undefined') {
            return null;
          }

          const __valueType = typeof __value;
          if (__valueType === 'number') {
            return Number.isFinite(__value) ? __value : null;
          }
          if (__valueType === 'string') {
            __cmuxChargeText(__value, __budget);
            return __value;
          }
          if (__valueType === 'bigint' || __valueType === 'symbol') {
            const __stringValue = String(__value);
            __cmuxChargeText(__stringValue, __budget);
            return __stringValue;
          }
          if (__valueType !== 'object' && __valueType !== 'function') {
            return __value;
          }

          if (__ancestors.has(__value)) {
            throw __cmuxCircularReference;
          }

          let __objectTag = '';
          try {
            __objectTag = Object.prototype.toString.call(__value);
          } catch (_) {}

          // iframe values have different constructors, so instanceof alone does
          // not recognize their DOMRect brand.
          const __isDOMRect =
            (typeof DOMRectReadOnly !== 'undefined' && __value instanceof DOMRectReadOnly) ||
            __objectTag === '[object DOMRect]' ||
            __objectTag === '[object DOMRectReadOnly]';
          if (__isDOMRect) {
            __ancestors.add(__value);
            try {
              return {
                x: __cmuxBridgeSafeValue(__value.x, __ancestors, __budget, __depth + 1),
                y: __cmuxBridgeSafeValue(__value.y, __ancestors, __budget, __depth + 1),
                width: __cmuxBridgeSafeValue(__value.width, __ancestors, __budget, __depth + 1),
                height: __cmuxBridgeSafeValue(__value.height, __ancestors, __budget, __depth + 1),
                top: __cmuxBridgeSafeValue(__value.top, __ancestors, __budget, __depth + 1),
                right: __cmuxBridgeSafeValue(__value.right, __ancestors, __budget, __depth + 1),
                bottom: __cmuxBridgeSafeValue(__value.bottom, __ancestors, __budget, __depth + 1),
                left: __cmuxBridgeSafeValue(__value.left, __ancestors, __budget, __depth + 1)
              };
            } finally {
              __ancestors.delete(__value);
            }
          }

          if (Array.isArray(__value)) {
            __ancestors.add(__value);
            try {
              const __copy = [];
              for (let __index = 0; __index < __value.length; __index += 1) {
                if (__budget.remainingNodes <= 0) {
                  throw __cmuxResultTooComplex;
                }
                __copy.push(__cmuxBridgeSafeValue(
                  __value[__index],
                  __ancestors,
                  __budget,
                  __depth + 1
                ));
              }
              return __copy;
            } finally {
              __ancestors.delete(__value);
            }
          }

          __ancestors.add(__value);
          try {
            const __copy = {};
            let __enumeratedKeys = 0;
            for (const __key in __value) {
              __enumeratedKeys += 1;
              if (__enumeratedKeys > 10000 || __budget.remainingNodes <= 0) {
                throw __cmuxResultTooComplex;
              }
              if (!Object.prototype.hasOwnProperty.call(__value, __key)) {
                continue;
              }
              __cmuxChargeText(__key, __budget);
              Object.defineProperty(__copy, __key, {
                value: __cmuxBridgeSafeValue(
                  __value[__key],
                  __ancestors,
                  __budget,
                  __depth + 1
                ),
                enumerable: true,
                configurable: true,
                writable: true
              });
            }
            return __copy;
          } finally {
            __ancestors.delete(__value);
          }
        };

        const __cmuxEvalInFrame = async function() {
          const document = __cmuxDoc;
          \(executionBlock)
          const __value = await __cmuxMaybeAwait(__r);
          if (typeof __value === 'undefined') {
            return { [\(typeKey)]: \(typeUndefined) };
          }
          let __cmuxSafeValue;
          try {
            __cmuxSafeValue = __cmuxBridgeSafeValue(__value);
          } catch (__error) {
            if (__error === __cmuxCircularReference) {
              return {
                [\(typeKey)]: \(typeError),
                [\(errorCodeKey)]: \(circularReferenceCode),
                [\(errorMessageKey)]: \(circularReferenceMessage)
              };
            }
            if (__error === __cmuxResultTooComplex) {
              return {
                [\(typeKey)]: \(typeError),
                [\(errorCodeKey)]: \(resultTooComplexCode),
                [\(errorMessageKey)]: \(operationFailedMessage)
              };
            }
            throw __error;
          }
          return {
            [\(typeKey)]: \(typeValue),
            [\(valueKey)]: __cmuxSafeValue
          };
        };

        return await __cmuxEvalInFrame();
        """
    }

    /// Resolves a raw WebKit value into its browser-eval envelope meaning.
    /// - Parameter rawValue: Value returned by WebKit.
    /// - Returns: The unwrapped value, `undefined`, or stable bridge error.
    public func resolveEvaluationEnvelope(_ rawValue: Any?) -> BrowserEvalEnvelopeResolution {
        guard let dictionary = rawValue as? [String: Any],
              let type = dictionary[evalEnvelope.typeKey] as? String else {
            return .unwrapped(rawValue)
        }

        switch type {
        case evalEnvelope.typeUndefined:
            return .undefined
        case evalEnvelope.typeValue:
            return .value(dictionary[evalEnvelope.valueKey])
        case evalEnvelope.typeError:
            guard let code = dictionary[evalEnvelope.errorCodeKey] as? String,
                  let message = dictionary[evalEnvelope.errorMessageKey] as? String else {
                return .unwrapped(rawValue)
            }
            return .error(code: code, message: message)
        default:
            return .unwrapped(rawValue)
        }
    }
}
