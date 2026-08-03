import Foundation

/// JavaScript evaluation wrapping and bridge-safe result handling.
extension BrowserControlService {
    /// Builds the complete function body used to evaluate browser JavaScript.
    ///
    /// The wrapper awaits promise-like results, converts DOM rectangles and
    /// JSON containers before they cross WebKit, duplicates repeated aliases,
    /// and emits a deterministic error envelope for a true circular reference.
    ///
    /// - Parameters:
    ///   - script: User or automation JavaScript to execute.
    ///   - useEval: Whether `script` is data passed to `eval`; when false it is
    ///     inserted as a trusted expression built by cmux.
    ///   - frameSelector: Optional selector for a same-origin frame document.
    /// - Returns: A JavaScript async-function body for WebKit evaluation.
    public func evaluationScript(
        script: String,
        useEval: Bool,
        frameSelector: String?
    ) -> String {
        let framePrelude: String
        if let frameSelector {
            let selectorLiteral = jsonLiteral(frameSelector)
            framePrelude = """
            let __cmuxDoc = document;
            try {
              const __cmuxFrame = document.querySelector(\(selectorLiteral));
              if (__cmuxFrame && __cmuxFrame.contentDocument) {
                __cmuxDoc = __cmuxFrame.contentDocument;
              }
            } catch (_) {}
            """
        } else {
            framePrelude = "const __cmuxDoc = document;"
        }

        let executionBlock = useEval
            ? "const __r = eval(\(jsonLiteral(script)));"
            : "const __r = \(script);"
        let typeKey = jsonLiteral(evalEnvelope.typeKey)
        let valueKey = jsonLiteral(evalEnvelope.valueKey)
        let typeUndefined = jsonLiteral(evalEnvelope.typeUndefined)
        let typeValue = jsonLiteral(evalEnvelope.typeValue)
        let typeError = jsonLiteral(evalEnvelope.typeError)
        let errorCodeKey = jsonLiteral(evalEnvelope.errorCodeKey)
        let errorMessageKey = jsonLiteral(evalEnvelope.errorMessageKey)
        let circularReferenceCode = jsonLiteral(evalEnvelope.circularReferenceCode)
        let circularReferenceMessage = jsonLiteral(evalEnvelope.circularReferenceMessage)

        return """
        \(framePrelude)

        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __cmuxCircularReference = Symbol('cmux.circularReference');
        const __cmuxBridgeSafeValue = (__value, __ancestors = new WeakSet()) => {
          if (__value === null || typeof __value !== 'object') {
            return __value;
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
            return {
              x: __value.x,
              y: __value.y,
              width: __value.width,
              height: __value.height,
              top: __value.top,
              right: __value.right,
              bottom: __value.bottom,
              left: __value.left
            };
          }

          if (__ancestors.has(__value)) {
            throw __cmuxCircularReference;
          }

          if (Array.isArray(__value)) {
            __ancestors.add(__value);
            try {
              const __copy = [];
              for (const __item of __value) {
                __copy.push(__cmuxBridgeSafeValue(__item, __ancestors));
              }
              return __copy;
            } finally {
              __ancestors.delete(__value);
            }
          }

          const __prototype = Object.getPrototypeOf(__value);
          if (__prototype === Object.prototype || __prototype === null) {
            __ancestors.add(__value);
            try {
              const __copy = {};
              for (const __key of Object.keys(__value)) {
                __copy[__key] = __cmuxBridgeSafeValue(__value[__key], __ancestors);
              }
              return __copy;
            } finally {
              __ancestors.delete(__value);
            }
          }

          return __value;
        };

        const __cmuxEvalInFrame = async function() {
          const document = __cmuxDoc;
          \(executionBlock)
          const __value = await __cmuxMaybeAwait(__r);
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
            throw __error;
          }
          return {
            [\(typeKey)]: (typeof __value === 'undefined') ? \(typeUndefined) : \(typeValue),
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
