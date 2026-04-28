import AppKit
import WebKit

@MainActor
protocol VoiceRealtimeWebRTCBridgeDelegate: AnyObject {
    func voiceRealtimeBridge(_ bridge: VoiceRealtimeWebRTCBridge, didReceiveMessage message: [String: Any])
}

@MainActor
private final class VoiceRealtimeWKWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class VoiceRealtimeWebRTCBridge: NSObject {
    weak var delegate: VoiceRealtimeWebRTCBridgeDelegate?

    let webView: WKWebView

    private let userContentController: WKUserContentController
    private var didLoadBridge = false
    private var pendingConnectConfig: [String: Any]?

    override init() {
        let userContentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.suppressesIncrementalRendering = true

        self.userContentController = userContentController
        self.webView = VoiceRealtimeWKWebView(frame: .zero, configuration: configuration)

        super.init()

        userContentController.add(VoiceWeakScriptMessageHandler(delegate: self), name: "cmuxRealtime")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.bridgeHTML, baseURL: URL(string: "https://cmux.local/realtime/"))
    }

    deinit {
        let userContentController = userContentController
        Task { @MainActor in
            userContentController.removeScriptMessageHandler(forName: "cmuxRealtime")
        }
    }

    func connect(ephemeralKey: String) {
        let config: [String: Any] = [
            "ephemeralKey": ephemeralKey
        ]
        guard didLoadBridge else {
            pendingConnectConfig = config
            return
        }
        evaluate(function: "window.cmuxRealtimeConnect", argument: config)
    }

    func disconnect() {
        pendingConnectConfig = nil
        evaluate(script: "window.cmuxRealtimeDisconnect && window.cmuxRealtimeDisconnect();")
    }

    func setMuted(_ muted: Bool) {
        evaluate(function: "window.cmuxRealtimeSetMuted", argument: muted)
    }

    func sendClientEvent(_ event: [String: Any]) {
        evaluate(function: "window.cmuxRealtimeSendClientEvent", argument: event)
    }

    private func evaluate(function: String, argument: Any) {
        do {
            let json = try VoiceJSON.string(from: ["argument": argument])
            let script = """
            (() => {
              const payload = \(json);
              \(function)(payload.argument);
            })();
            """
            evaluate(script: script)
        } catch {
            delegate?.voiceRealtimeBridge(self, didReceiveMessage: [
                "kind": "error",
                "message": error.localizedDescription
            ])
        }
    }

    private func evaluate(script: String) {
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, let error else { return }
            Task { @MainActor in
                self.delegate?.voiceRealtimeBridge(self, didReceiveMessage: [
                    "kind": "error",
                    "message": error.localizedDescription
                ])
            }
        }
    }

    private static let bridgeHTML = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        audio { width: 1px; height: 1px; opacity: 0.01; }
      </style>
    </head>
    <body>
      <audio id="remoteAudio" autoplay playsinline></audio>
      <script>
        (() => {
          let pc = null;
          let dc = null;
          let localStream = null;
          const meter = (() => {
            let state = {
              audioContext: null,
              analyser: null,
              source: null,
              timer: null,
              buffer: null
            };

            const stop = () => {
              if (state.timer) window.clearInterval(state.timer);
              state.timer = null;
              try {
                if (state.source) state.source.disconnect();
              } catch (_) {}
              state.source = null;
              try {
                if (state.audioContext) state.audioContext.close();
              } catch (_) {}
              state.audioContext = null;
              state.analyser = null;
              state.buffer = null;
            };

            const start = (stream) => {
              stop();
              const AudioContextType = window.AudioContext || window.webkitAudioContext;
              if (!AudioContextType) return;
              try {
                state.audioContext = new AudioContextType();
                if (state.audioContext.state === "suspended") {
                  state.audioContext.resume().catch(() => {});
                }
                state.analyser = state.audioContext.createAnalyser();
                state.analyser.fftSize = 512;
                state.buffer = new Uint8Array(state.analyser.fftSize);
                state.source = state.audioContext.createMediaStreamSource(stream);
                state.source.connect(state.analyser);
                state.timer = window.setInterval(() => {
                  if (!state.analyser || !state.buffer) return;
                  state.analyser.getByteTimeDomainData(state.buffer);
                  let sum = 0;
                  for (const value of state.buffer) {
                    const centered = (value - 128) / 128;
                    sum += centered * centered;
                  }
                  const rms = Math.sqrt(sum / state.buffer.length);
                  post({ kind: "audio_level", level: Math.min(1, rms * 8) });
                }, 150);
              } catch (error) {
                post({ kind: "log", message: String(error && error.message ? error.message : error) });
              }
            };

            return { start, stop };
          })();

          const post = (message) => {
            try {
              window.webkit.messageHandlers.cmuxRealtime.postMessage(message);
            } catch (_) {}
          };

          const setState = (state) => post({ kind: "state", state });
          const setError = (message) => post({ kind: "error", message: String(message || "Unknown WebRTC error") });

          const waitForIceGatheringComplete = (peerConnection) => {
            if (!peerConnection || peerConnection.iceGatheringState === "complete") {
              return Promise.resolve();
            }
            return new Promise((resolve) => {
              const timeout = window.setTimeout(resolve, 2500);
              const listener = () => {
                if (peerConnection.iceGatheringState === "complete") {
                  window.clearTimeout(timeout);
                  peerConnection.removeEventListener("icegatheringstatechange", listener);
                  resolve();
                }
              };
              peerConnection.addEventListener("icegatheringstatechange", listener);
            });
          };

          const closeCurrent = () => {
            meter.stop();
            try {
              if (dc) dc.close();
            } catch (_) {}
            dc = null;
            try {
              if (pc) pc.close();
            } catch (_) {}
            pc = null;
            try {
              if (localStream) {
                for (const track of localStream.getTracks()) track.stop();
              }
            } catch (_) {}
            localStream = null;
            const audio = document.getElementById("remoteAudio");
            if (audio) audio.srcObject = null;
          };

          window.cmuxRealtimeConnect = async (config) => {
            try {
              closeCurrent();
              setState("connecting");

              if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
                throw new Error("Microphone capture is unavailable in this WebView.");
              }

              pc = new RTCPeerConnection({ bundlePolicy: "max-bundle" });
              pc.onconnectionstatechange = () => {
                if (!pc) return;
                post({ kind: "connection_state", state: pc.connectionState });
                if (pc.connectionState === "failed") setState("failed");
                if (pc.connectionState === "disconnected" || pc.connectionState === "closed") setState("disconnected");
              };
              pc.ontrack = (event) => {
                const audio = document.getElementById("remoteAudio");
                if (!audio) return;
                audio.srcObject = event.streams[0];
                audio.play().catch((error) => {
                  post({ kind: "log", message: String(error && error.message ? error.message : error) });
                });
              };

              localStream = await navigator.mediaDevices.getUserMedia({
                audio: {
                  echoCancellation: true,
                  noiseSuppression: true,
                  autoGainControl: true
                }
              });
              post({ kind: "microphone_ready" });
              meter.start(localStream);
              for (const track of localStream.getTracks()) {
                pc.addTrack(track, localStream);
              }

              dc = pc.createDataChannel("oai-events");
              dc.onopen = () => setState("connected");
              dc.onclose = () => setState("disconnected");
              dc.onerror = (event) => setError(event && event.message ? event.message : "Realtime data channel error.");
              dc.onmessage = (event) => {
                try {
                  post({ kind: "server_event", event: JSON.parse(event.data) });
                } catch (error) {
                  post({ kind: "server_event_parse_error", message: String(error), raw: String(event.data || "") });
                }
              };

              const offer = await pc.createOffer();
              await pc.setLocalDescription(offer);
              await waitForIceGatheringComplete(pc);

              const response = await fetch("https://api.openai.com/v1/realtime/calls", {
                method: "POST",
                headers: {
                  "Authorization": `Bearer ${config.ephemeralKey}`,
                  "Content-Type": "application/sdp"
                },
                body: pc.localDescription.sdp
              });

              const answerSDP = await response.text();
              if (!response.ok) {
                throw new Error(`Realtime SDP request failed with HTTP ${response.status}: ${answerSDP}`);
              }
              await pc.setRemoteDescription({ type: "answer", sdp: answerSDP });
            } catch (error) {
              closeCurrent();
              setState("failed");
              setError(error && error.message ? error.message : error);
            }
          };

          window.cmuxRealtimeDisconnect = () => {
            closeCurrent();
            setState("disconnected");
          };

          window.cmuxRealtimeSetMuted = (muted) => {
            if (!localStream) return;
            for (const track of localStream.getAudioTracks()) {
              track.enabled = !muted;
            }
            post({ kind: "mute_state", muted: !!muted });
          };

          window.cmuxRealtimeSendClientEvent = (event) => {
            if (!dc || dc.readyState !== "open") {
              setError("Realtime data channel is not open.");
              return;
            }
            dc.send(JSON.stringify(event));
          };

          post({ kind: "bridge_ready" });
        })();
      </script>
    </body>
    </html>
    """
}

extension VoiceRealtimeWebRTCBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didLoadBridge = true
        if let pendingConnectConfig {
            self.pendingConnectConfig = nil
            evaluate(function: "window.cmuxRealtimeConnect", argument: pendingConnectConfig)
        }
    }
}

extension VoiceRealtimeWebRTCBridge: WKUIDelegate {
    @available(macOS 12.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }
}

extension VoiceRealtimeWebRTCBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dictionary = message.body as? [String: Any] else {
            delegate?.voiceRealtimeBridge(self, didReceiveMessage: [
                "kind": "error",
                "message": String(localized: "voice.error.invalidBridgeMessage", defaultValue: "Invalid WebRTC bridge message.")
            ])
            return
        }
        delegate?.voiceRealtimeBridge(self, didReceiveMessage: dictionary)
    }
}

@MainActor
private final class VoiceWeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: VoiceRealtimeWebRTCBridge?

    init(delegate: VoiceRealtimeWebRTCBridge) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
