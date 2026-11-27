public import Foundation

/// The page-world JavaScript that applies the overrides in one frame.
///
/// The first run in a document wraps `Geolocation.prototype`
/// (`getCurrentPosition`, `watchPosition`, `clearWatch`) and the
/// `Navigator.prototype.onLine` getter; every run stores the current values.
/// The wrappers defer to WebKit's own implementation whenever no override is
/// set, so a run with default values leaves the page's behavior unchanged.
/// Running the script again in the same document only updates the values,
/// which is how a later `set` reaches a page that is already loaded.
///
/// Requests are answered from the stored position without a permission
/// prompt, like Chromium's geolocation override for an automated tab.
extension BrowserEmulationOverrides {
    /// The global symbol key of the per-document state (`Symbol.for`).
    public static let pageScriptStateKey = "cmux.browser.emulation"

    /// The script for these overrides.
    /// - Parameter dispatchesChangeEvents: `true` for a run in a loaded
    ///   document: fires `offline`/`online` on `window` when the network state
    ///   flips and reports a new position to active `watchPosition` callers.
    ///   Document-start runs pass `false`.
    public func pageScript(dispatchesChangeEvents: Bool) -> String {
        "(\(Self.pageScriptInstaller))(\(pageScriptConfigurationJSON), \(dispatchesChangeEvents ? "true" : "false"));"
    }

    var pageScriptConfigurationJSON: String {
        let geolocationJSON: String
        if let position = geolocation {
            // `description` round-trips a finite Double and never uses a locale.
            geolocationJSON = "{\"latitude\":\(position.latitude.description),"
                + "\"longitude\":\(position.longitude.description),"
                + "\"accuracy\":\(position.accuracy.description)}"
        } else {
            geolocationJSON = "null"
        }
        return "{\"geolocation\":\(geolocationJSON),\"offline\":\(offline ? "true" : "false")}"
    }

    private static let pageScriptInstaller = #"""
    function (config, notify) {
      'use strict';
      const key = Symbol.for('\#(pageScriptStateKey)');
      let state = globalThis[key];
      if (!state) {
        state = { geolocation: null, offline: false, watches: new Map(), nextWatchID: 1000000000, deliver: null };
        Object.defineProperty(globalThis, key, { value: state, configurable: false, enumerable: false, writable: false });

        const makePosition = (g) => {
          const coords = {
            latitude: g.latitude, longitude: g.longitude, accuracy: g.accuracy,
            altitude: null, altitudeAccuracy: null, heading: null, speed: null,
          };
          coords.toJSON = () => ({
            latitude: coords.latitude, longitude: coords.longitude, accuracy: coords.accuracy,
            altitude: null, altitudeAccuracy: null, heading: null, speed: null,
          });
          const position = { coords, timestamp: Date.now() };
          position.toJSON = () => ({ coords: coords.toJSON(), timestamp: position.timestamp });
          return position;
        };
        // The position is the one set when the request was made, as a real
        // fix is taken when requested.
        state.deliver = (callback) => {
          const g = state.geolocation;
          setTimeout(() => { if (g) { callback(makePosition(g)); } }, 0);
        };

        const proto = globalThis.Geolocation && globalThis.Geolocation.prototype;
        if (proto) {
          const nativeGet = proto.getCurrentPosition;
          const nativeWatch = proto.watchPosition;
          const nativeClear = proto.clearWatch;
          const define = (name, value) => Object.defineProperty(proto, name, {
            value, writable: true, enumerable: true, configurable: true,
          });
          define('getCurrentPosition', function getCurrentPosition(success) {
            if (!state.geolocation || typeof success !== 'function') {
              return nativeGet.apply(this, arguments);
            }
            state.deliver(success);
          });
          define('watchPosition', function watchPosition(success) {
            if (!state.geolocation || typeof success !== 'function') {
              return nativeWatch.apply(this, arguments);
            }
            const id = state.nextWatchID++;
            state.watches.set(id, success);
            state.deliver(success);
            return id;
          });
          define('clearWatch', function clearWatch(id) {
            if (state.watches.delete(id)) { return; }
            return nativeClear.apply(this, arguments);
          });
        }

        const navigatorProto = globalThis.Navigator && globalThis.Navigator.prototype;
        const onLine = navigatorProto && Object.getOwnPropertyDescriptor(navigatorProto, 'onLine');
        if (onLine && typeof onLine.get === 'function' && onLine.configurable) {
          const nativeOnLine = onLine.get;
          Object.defineProperty(navigatorProto, 'onLine', {
            get: function () { return state.offline ? false : nativeOnLine.call(this); },
            enumerable: onLine.enumerable, configurable: true,
          });
        }
      }

      const wasOffline = state.offline;
      state.geolocation = config.geolocation;
      state.offline = config.offline;
      if (notify) {
        if (wasOffline !== state.offline && typeof globalThis.dispatchEvent === 'function') {
          globalThis.dispatchEvent(new Event(state.offline ? 'offline' : 'online'));
        }
        if (state.geolocation) {
          for (const callback of state.watches.values()) { state.deliver(callback); }
        }
      }
      return true;
    }
    """#
}
