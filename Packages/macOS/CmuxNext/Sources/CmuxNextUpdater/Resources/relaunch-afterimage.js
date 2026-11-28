// The relaunch afterimage (RelaunchAfterimage.swift): run by /usr/bin/osascript -l JavaScript, never by the app.
//
// Leo, 2026-11-22: "we need to have far more graceful reloads that appear to just be instantly gracefully transitioned
// ... no shift, no anything, just... ok now it changed". A relaunch's old process leaves the screen before the new one
// draws (the quit, an installer's swap, the launch: one to three seconds of no window). This process outlives the old
// one and keeps a picture of each of its windows on screen, at the same frame and place in the window order, until the
// new process says it drew its own (the `painted` file) or a deadline passes. It is a separate, system-signed process
// that LaunchServices does not count as the app, so the relaunch's `open` still starts the new copy.
//
// argv[0]: the folder RelaunchAfterimage wrote, holding plan.json and one PNG per window:
//   {"activates": bool, "deadlineMs": n, "windows": [{"image": "w0.png", "x", "y", "w", "h", "above": n}, ...]}
// windows run back to front; x/y/w/h is the window's frame in AppKit screen points; above is the old window's number,
// which the picture is ordered just above (0: in front). Writes `shown` (the pictures' window numbers) once they are up.
// Removes the folder when it ends. Ends at `painted`, at the deadline (a short fade), or when the folder disappears.
ObjC.import('Cocoa');
ObjC.import('CoreGraphics');

function run(argv) {
  const dir = argv[0];
  const fm = $.NSFileManager.defaultManager;
  const data = $.NSData.dataWithContentsOfFile(dir + '/plan.json');
  if (!data || data.isNil()) return 'no plan';
  const plan = JSON.parse($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js);
  const app = $.NSApplication.sharedApplication;
  // No Dock icon and no menu bar of its own.
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);
  const shown = [];
  for (const w of plan.windows) {
    const image = $.NSImage.alloc.initWithContentsOfFile(dir + '/' + w.image);
    if (!image || image.isNil()) continue;
    const rect = $.NSMakeRect(w.x, w.y, w.w, w.h);
    const win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(rect, $.NSWindowStyleMaskBorderless, $.NSBackingStoreBuffered, false);
    win.releasedWhenClosed = false;
    win.opaque = false;
    win.backgroundColor = $.NSColor.clearColor;
    win.hasShadow = true;
    win.animationBehavior = $.NSWindowAnimationBehaviorNone;
    // Over a full-screen space too, where the old window was.
    win.collectionBehavior = $.NSWindowCollectionBehaviorFullScreenAuxiliary | $.NSWindowCollectionBehaviorIgnoresCycle;
    const view = $.NSImageView.alloc.initWithFrame($.NSMakeRect(0, 0, w.w, w.h));
    view.imageScaling = $.NSImageScaleAxesIndependently;
    view.image = image;
    win.contentView = view;
    // Drawn (the PNG decoded) before it is ordered in, so its first frame on screen is the picture.
    win.display;
    if (w.above > 0) win.orderWindowRelativeTo($.NSWindowAbove, w.above); else win.orderFrontRegardless;
    shown.push(win);
  }
  // A click the person asked for comes back in front (the new copy activates); an unclicked one stays where it was.
  if (plan.activates) app.activateIgnoringOtherApps(true);
  const loop = $.NSRunLoop.currentRunLoop;
  // `shown` only once the window server lists every picture on screen (a commit can lag the order by a frame or more).
  const numbers = shown.map((w) => Number(w.windowNumber));
  for (let i = 0; i < 60; i++) {
    loop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(1 / 120));
    const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0))) || [];
    const up = new Set(list.map((w) => w.kCGWindowNumber));
    if (numbers.every((n) => up.has(n))) break;
  }
  // One more frame: listed is committed, this is presented.
  loop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(1 / 60));
  // The old copy waits for this file before its own windows go (never a frame with neither on screen). A file, not
  // stdout: the old copy may be gone by the time anything here writes, and a write to its pipe would end this process.
  $(shown.map((w) => w.windowNumber).join(',')).writeToFileAtomicallyEncodingError(dir + '/shown', true, $.NSUTF8StringEncoding, null);
  const started = Date.now(), deadline = plan.deadlineMs || 8000;
  let why = 'deadline';
  while (Date.now() - started < deadline) {
    if (fm.fileExistsAtPath(dir + '/painted')) { why = 'painted'; break; }
    if (!fm.fileExistsAtPath(dir + '/plan.json')) { why = 'gone'; break; }
    loop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(1 / 120));
  }
  // The new copy's windows are over the pictures by now: closing them shows nothing. At the deadline (no new copy drew)
  // they fade, never a cut to an empty desktop.
  if (why === 'deadline') {
    for (let step = 1; step <= 9; step++) {
      for (const win of shown) win.alphaValue = 1 - step / 9;
      loop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(1 / 60));
    }
  }
  for (const win of shown) win.orderOut(null);
  fm.removeItemAtPathError(dir, null);
  return why + ' ' + (Date.now() - started);
}
