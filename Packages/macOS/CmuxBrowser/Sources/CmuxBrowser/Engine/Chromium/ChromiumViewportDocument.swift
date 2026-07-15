import Foundation

/// Builds the local canvas document used to display and interact with CDP screencast frames.
struct ChromiumViewportDocument {
    func html(loadingText: String, accessibilityLabel: String) -> String {
        let encodedLoadingText = jsonLiteral(loadingText)
        let encodedAccessibilityLabel = jsonLiteral(accessibilityLabel)
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; background: #fff; }
            body { font: 13px -apple-system, system-ui, sans-serif; color: #666; }
            canvas { display: block; width: 100%; height: 100%; outline: none; cursor: default; }
            #textInput { position: fixed; top: 0; left: 0; width: 1px; height: 1px; opacity: 0; pointer-events: none; }
            #status { position: fixed; inset: 0; display: grid; place-items: center; padding: 24px; text-align: center; }
            body.ready #status { display: none; }
          </style>
        </head>
        <body>
          <div id="status"></div>
          <canvas id="viewport"></canvas>
          <textarea id="textInput" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"></textarea>
          <script>
            const bridge = window.webkit.messageHandlers.cmuxChromiumViewport;
            const canvas = document.getElementById('viewport');
            const textInput = document.getElementById('textInput');
            const status = document.getElementById('status');
            canvas.setAttribute('aria-label', \(encodedAccessibilityLabel));
            textInput.setAttribute('aria-label', \(encodedAccessibilityLabel));
            status.textContent = \(encodedLoadingText);
            const context = canvas.getContext('2d', { alpha: false });
            let cssWidth = 1;
            let cssHeight = 1;
            let deviceScaleFactor = window.devicePixelRatio || 1;

            function post(type, values = {}) { bridge.postMessage({ type, ...values }); }
            function resize() {
              const rect = canvas.getBoundingClientRect();
              cssWidth = Math.max(1, Math.round(rect.width));
              cssHeight = Math.max(1, Math.round(rect.height));
              deviceScaleFactor = window.devicePixelRatio || 1;
              canvas.width = Math.max(1, Math.round(cssWidth * deviceScaleFactor));
              canvas.height = Math.max(1, Math.round(cssHeight * deviceScaleFactor));
              post('resize', { width: cssWidth, height: cssHeight, scale: deviceScaleFactor });
            }
            new ResizeObserver(resize).observe(canvas);
            resize();

            window.cmuxChromiumFrame = async function(dataURL) {
              const image = new Image();
              image.src = dataURL;
              await image.decode();
              context.drawImage(image, 0, 0, canvas.width, canvas.height);
              document.body.classList.add('ready');
              return true;
            };
            window.cmuxChromiumError = function(message) {
              status.textContent = String(message || '');
              document.body.classList.remove('ready');
            };

            function point(event) {
              const rect = canvas.getBoundingClientRect();
              return { x: event.clientX - rect.left, y: event.clientY - rect.top };
            }
            function modifiers(event) {
              return (event.altKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) |
                     (event.metaKey ? 4 : 0) | (event.shiftKey ? 8 : 0);
            }
            function focusTextInput() {
              textInput.focus({ preventScroll: true });
              textInput.setSelectionRange(textInput.value.length, textInput.value.length);
            }
            canvas.addEventListener('mousedown', event => {
              focusTextInput();
              const p = point(event);
              post('mouse', { event: 'mousePressed', x: p.x, y: p.y, button: event.button, modifiers: modifiers(event), clickCount: event.detail });
              event.preventDefault();
            });
            canvas.addEventListener('mouseup', event => {
              const p = point(event);
              post('mouse', { event: 'mouseReleased', x: p.x, y: p.y, button: event.button, modifiers: modifiers(event), clickCount: event.detail });
              event.preventDefault();
            });
            canvas.addEventListener('mousemove', event => {
              const p = point(event);
              post('mouse', { event: 'mouseMoved', x: p.x, y: p.y, button: event.buttons ? event.button : -1, modifiers: modifiers(event), clickCount: 0 });
            });
            canvas.addEventListener('wheel', event => {
              const p = point(event);
              post('mouse', { event: 'mouseWheel', x: p.x, y: p.y, button: -1, modifiers: modifiers(event), deltaX: event.deltaX, deltaY: event.deltaY, clickCount: 0 });
              event.preventDefault();
            }, { passive: false });
            let isComposing = false;
            const suppressedKeyUps = new Set();
            textInput.addEventListener('keydown', event => {
              const plainText = event.key.length === 1 && !event.metaKey && !event.ctrlKey;
              const pasteShortcut = event.code === 'KeyV' && (event.metaKey || event.ctrlKey);
              if (pasteShortcut) {
                suppressedKeyUps.add(event.code);
              } else {
                post('key', { event: 'keyDown', key: event.key, code: event.code, modifiers: modifiers(event), text: '' });
              }
              if (!plainText && !pasteShortcut && !event.isComposing && event.key !== 'Dead' && event.key !== 'Process') {
                event.preventDefault();
              }
            });
            textInput.addEventListener('keyup', event => {
              if (suppressedKeyUps.delete(event.code)) {
                event.preventDefault();
                return;
              }
              post('key', { event: 'keyUp', key: event.key, code: event.code, modifiers: modifiers(event), text: '' });
              event.preventDefault();
            });
            textInput.addEventListener('beforeinput', event => {
              if (isComposing || event.isComposing || event.inputType === 'insertCompositionText' || event.inputType === 'insertFromComposition') {
                return;
              }
              if (event.inputType.startsWith('insert') && event.data) {
                post('text', { text: event.data });
              }
              event.preventDefault();
            });
            textInput.addEventListener('compositionstart', () => {
              isComposing = true;
            });
            textInput.addEventListener('compositionupdate', event => {
              const text = String(event.data || '');
              post('composition', { text, selectionStart: text.length, selectionEnd: text.length });
            });
            textInput.addEventListener('compositionend', event => {
              const text = String(event.data || '');
              isComposing = false;
              post('composition', { text: '', selectionStart: 0, selectionEnd: 0 });
              if (text) post('text', { text });
              textInput.value = '';
            });
            textInput.addEventListener('paste', event => {
              const text = event.clipboardData?.getData('text/plain') || '';
              if (text) post('text', { text });
              event.preventDefault();
            });
            textInput.addEventListener('input', () => {
              if (!isComposing) textInput.value = '';
            });
            window.addEventListener('focus', focusTextInput);
            focusTextInput();
          </script>
        </body>
        </html>
        """
    }

    private func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let result = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return result
    }
}
