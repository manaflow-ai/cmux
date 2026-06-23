import Foundation

/// The WebKit `showOpenFilePicker` polyfill injected at document start so pages
/// that call the File System Access API fall back to a hidden `<input type=file>`
/// element instead of throwing.
///
/// The script installs a `window.showOpenFilePicker` implementation (plus
/// `FileSystemHandle`/`FileSystemFileHandle` shims) that resolves with handles
/// wrapping the selected `File` objects, rejecting with an `AbortError` when the
/// picker is dismissed. The single consumer passes ``scriptSource`` as the source
/// of a `WKUserScript`.
public struct BrowserFileSystemAccessBridge: Sendable {
    /// The JavaScript source for the `showOpenFilePicker` polyfill.
    public static let scriptSource = """
    (() => {
      if (typeof window.showOpenFilePicker === "function") {
        return true;
      }
      if (window.__cmuxFileSystemAccessBridgeInstalled) {
        return true;
      }
      window.__cmuxFileSystemAccessBridgeInstalled = true;

      const makeDOMException = (name, message) => {
        try {
          return new DOMException(message, name);
        } catch (_) {
          const error = new Error(message);
          error.name = name;
          return error;
        }
      };

      const normalizeAcceptToken = (value) => {
        if (typeof value !== "string") {
          return null;
        }
        const token = value.trim();
        return token.length > 0 ? token : null;
      };

      const acceptStringFromTypes = (types) => {
        if (!Array.isArray(types)) {
          return "";
        }

        const seen = new Set();
        const tokens = [];
        const pushToken = (value) => {
          const token = normalizeAcceptToken(value);
          if (token && !seen.has(token)) {
            seen.add(token);
            tokens.push(token);
          }
        };

        for (const type of types) {
          const accept = type && type.accept;
          if (!accept || typeof accept !== "object") {
            continue;
          }

          for (const [mimeType, extensions] of Object.entries(accept)) {
            pushToken(mimeType);
            if (Array.isArray(extensions)) {
              for (const extension of extensions) {
                pushToken(extension);
              }
            } else {
              pushToken(extensions);
            }
          }
        }

        return tokens.join(",");
      };

      const FileSystemHandleShim = window.FileSystemHandle || function FileSystemHandle() {};
      const FileSystemFileHandleShim = window.FileSystemFileHandle || function FileSystemFileHandle() {};
      if (typeof window.FileSystemHandle !== "function") {
        Object.defineProperty(window, "FileSystemHandle", {
          value: FileSystemHandleShim,
          configurable: true,
          writable: true,
        });
      }
      if (typeof window.FileSystemFileHandle !== "function") {
        FileSystemFileHandleShim.prototype = Object.create(FileSystemHandleShim.prototype);
        Object.defineProperty(FileSystemFileHandleShim.prototype, "constructor", {
          value: FileSystemFileHandleShim,
          configurable: true,
          writable: true,
        });
        Object.defineProperty(window, "FileSystemFileHandle", {
          value: FileSystemFileHandleShim,
          configurable: true,
          writable: true,
        });
      }

      const makeFileHandle = (file) => {
        const handle = Object.create(window.FileSystemFileHandle.prototype);
        Object.defineProperties(handle, {
          kind: {
            value: "file",
            enumerable: true,
          },
          name: {
            value: file.name,
            enumerable: true,
          },
          getFile: {
            value: () => Promise.resolve(file),
          },
          isSameEntry: {
            value: (other) => Promise.resolve(other === handle),
          },
          queryPermission: {
            value: () => Promise.resolve("granted"),
          },
          requestPermission: {
            value: () => Promise.resolve("granted"),
          },
        });
        return handle;
      };

      const filePickerDismissedError = () => makeDOMException(
        "AbortError",
        "The file picker was dismissed."
      );

      const cleanupInput = (input) => {
        if (input && input.parentNode) {
          input.parentNode.removeChild(input);
        }
      };

      const showOpenFilePicker = (options = {}) => new Promise((resolve, reject) => {
        const input = document.createElement("input");
        input.type = "file";
        input.multiple = options && options.multiple === true;
        const accept = acceptStringFromTypes(options && options.types);
        if (accept) {
          input.accept = accept;
        }
        input.style.position = "fixed";
        input.style.left = "-10000px";
        input.style.top = "0";
        input.style.width = "1px";
        input.style.height = "1px";
        input.style.opacity = "0";
        input.tabIndex = -1;

        let settled = false;
        let focusFallbackScheduled = false;
        let focusFallbackTimer = null;
        const currentFiles = () => Array.from(input.files || []);
        const cleanup = () => {
          if (focusFallbackTimer !== null) {
            clearTimeout(focusFallbackTimer);
            focusFallbackTimer = null;
          }
          input.removeEventListener("change", handleChange);
          input.removeEventListener("cancel", handleCancel);
          window.removeEventListener("focus", handleWindowFocus);
          cleanupInput(input);
        };
        const settle = (callback) => {
          if (settled) {
            return;
          }
          settled = true;
          cleanup();
          callback();
        };

        const resolveFiles = () => {
          const files = currentFiles();
          settle(() => resolve(files.map(makeFileHandle)));
        };

        const dismissPicker = () => {
          settle(() => reject(filePickerDismissedError()));
        };

        function handleChange() {
          resolveFiles();
        }

        function handleCancel() {
          dismissPicker();
        }

        function handleWindowFocus() {
          if (settled || focusFallbackScheduled) {
            return;
          }
          focusFallbackScheduled = true;
          // Defer one turn so a selection-triggered change event can settle first.
          focusFallbackTimer = setTimeout(() => {
            focusFallbackTimer = null;
            if (settled) {
              return;
            }
            if (currentFiles().length > 0) {
              resolveFiles();
            } else {
              dismissPicker();
            }
          }, 0);
        }

        input.addEventListener("change", handleChange);
        input.addEventListener("cancel", handleCancel);
        window.addEventListener("focus", handleWindowFocus);

        try {
          (document.body || document.documentElement).appendChild(input);
          input.click();
        } catch (error) {
          settle(() => reject(error));
        }
      });

      Object.defineProperty(window, "showOpenFilePicker", {
        value: showOpenFilePicker,
        configurable: true,
        writable: true,
      });

      return true;
    })();
    """
}
