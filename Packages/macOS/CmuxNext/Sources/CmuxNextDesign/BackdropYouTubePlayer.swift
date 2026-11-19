public import AppKit
import WebKit

/// One YouTube player behind a window (``BackdropYouTubePlayers`` owns it, a
/// ``BackdropYouTubeView`` shows it). Tests stand in their own.
@MainActor public protocol BackdropYouTubePlaying: AnyObject {
    /// The view that draws the player, laid out at the video's player size.
    var view: NSView { get }
    /// Whether a frame has played (the view fades it in over the poster once).
    var hasPlayed: Bool { get }
    /// Where it is, in whole seconds, to pick up from after a release.
    var position: Int { get }
    /// Told on the first playing frame, and when the embed refuses the video.
    var onEvent: (@MainActor (BackdropYouTubePlayerEvent) -> Void)? { get set }
    func play()
    func pause()
    /// Ends it for good (unloads the page).
    func close()
}

/// What a player tells its owner.
public enum BackdropYouTubePlayerEvent: Equatable, Sendable {
    /// The first frame plays.
    case playing
    /// The embed refused the video (removed, private, or not embeddable): the poster stays.
    case failed(code: Int)
}

/// The YouTube IFrame Player embed (www.youtube-nocookie.com) in a web view: muted, autoplay,
/// no controls, keyboard, fullscreen, related videos or annotations, inline, looping between the
/// wallpaper's start and end through the player API. The page is loaded from a string with an
/// https base URL so the embed gets a referrer, in a nonpersistent website data store (no cookie
/// or cache outlives it). The stream is never downloaded or kept; only the embed plays it, and
/// the player's own attribution and links are left as YouTube draws them.
@MainActor
final class BackdropYouTubePlayer: NSObject, BackdropYouTubePlaying, WKNavigationDelegate {
    let video: BackdropYouTube
    private let webView: BackdropYouTubeWebView
    private var wantsPlay = false
    private var loaded = false
    private(set) var hasPlayed = false
    private(set) var position: Int
    var onEvent: (@MainActor (BackdropYouTubePlayerEvent) -> Void)?

    /// The page's origin: the embed's referrer.
    static let origin = "https://cmux.com"

    var view: NSView { webView }

    /// A player of `video` that starts at `resumeAt` seconds (its loop start when nil).
    init(video: BackdropYouTube, resumeAt: Int? = nil) {
        self.video = video
        position = resumeAt ?? video.start
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.allowsAirPlayForMediaPlayback = false
        webView = BackdropYouTubeWebView(frame: NSRect(origin: .zero, size: video.playerSize(backingScale: 2)),
                                         configuration: configuration)
        super.init()
        configuration.userContentController.add(BackdropYouTubeMessages(self), name: "cmux")
        webView.navigationDelegate = self
        webView.wantsLayer = true
        webView.setAccessibilityElement(false)
        webView.loadHTMLString(Self.page(video, startAt: position), baseURL: URL(string: Self.origin + "/"))
    }

    func play() {
        wantsPlay = true
        guard loaded else { return }
        webView.evaluateJavaScript("cmuxPlay()", completionHandler: nil)
    }

    func pause() {
        wantsPlay = false
        guard loaded else { return }
        webView.evaluateJavaScript("cmuxPause()", completionHandler: nil)
    }

    func close() {
        wantsPlay = false
        onEvent = nil
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmux")
        webView.stopLoading()
        WebViewRetirement.retire(webView)
    }

    // MARK: The page's messages

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let event = body["e"] as? String else { return }
        if let seconds = body["t"] as? Double, seconds.isFinite, seconds >= 0 { position = Int(seconds) }
        switch event {
        case "ready":
            loaded = true
            webView.evaluateJavaScript(wantsPlay ? "cmuxPlay()" : "cmuxPause()", completionHandler: nil)
        case "playing":
            guard !hasPlayed else { return }
            hasPlayed = true
            onEvent?(.playing)
        case "error":
            onEvent?(.failed(code: body["c"] as? Int ?? 0))
        default:
            break
        }
    }

    /// Only the page itself loads in the top frame: a link in the player (its title, the YouTube
    /// mark) never navigates the wallpaper away. The embed's own frames load as they ask.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let topFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let url = navigationAction.request.url
        let page = url?.absoluteString == Self.origin + "/" || url?.scheme == "about"
        decisionHandler(!topFrame || page ? .allow : .cancel)
    }

    /// The HTML of the page: the IFrame API and a player filling it.
    static func page(_ video: BackdropYouTube, startAt: Int) -> String {
        let end = video.end.map(String.init) ?? "0"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}#p{width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script>
        var loopStart=\(video.start),loopEnd=\(end),want=false,player=null,watch=null;
        function post(m){try{window.webkit.messageHandlers.cmux.postMessage(m)}catch(e){}}
        function now(){return player&&player.getCurrentTime?player.getCurrentTime():0}
        function guardEnd(on){clearInterval(watch);watch=null;if(on&&loopEnd>0){watch=setInterval(function(){
          if(now()>=loopEnd){player.seekTo(loopStart,true)}},500)}}
        function onYouTubeIframeAPIReady(){player=new YT.Player('p',{host:'https://www.youtube-nocookie.com',
          videoId:'\(video.videoID)',width:'100%',height:'100%',
          playerVars:{autoplay:0,mute:1,controls:0,disablekb:1,fs:0,rel:0,iv_load_policy:3,playsinline:1,
            enablejsapi:1,start:\(startAt),origin:'\(origin)'},
          events:{onReady:function(e){e.target.mute();post({e:'ready',t:now()})},
            onStateChange:function(e){
              if(e.data===YT.PlayerState.ENDED){player.seekTo(loopStart,true);if(want)player.playVideo();return}
              if(e.data===YT.PlayerState.PLAYING){guardEnd(true);post({e:'playing',t:now()})}
              else if(e.data===YT.PlayerState.PAUSED){guardEnd(false);post({e:'paused',t:now()})}},
            onError:function(e){post({e:'error',c:e.data})}}})}
        function cmuxPlay(){want=true;if(player&&player.playVideo){player.mute();player.playVideo()}}
        function cmuxPause(){want=false;guardEnd(false);if(player&&player.pauseVideo){player.pauseVideo()}post({e:'paused',t:now()})}
        </script><script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }
}

/// Holds the player weakly: the user content controller keeps its handlers.
@MainActor
private final class BackdropYouTubeMessages: NSObject, WKScriptMessageHandler {
    weak var player: BackdropYouTubePlayer?

    init(_ player: BackdropYouTubePlayer) {
        self.player = player
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        player?.userContentController(controller, didReceive: message)
    }
}

/// The web view of a wallpaper: decoration only. It takes no click, key or focus, and is not in
/// the accessibility tree (VoiceOver reads the window's content, not the wallpaper).
final class BackdropYouTubeWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}
