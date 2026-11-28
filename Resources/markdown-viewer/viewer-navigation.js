(function(global) {
  'use strict';

  var actionMotions = [
    ['diffViewerScrollDown', 'line', 1],
    ['diffViewerScrollUp', 'line', -1],
    ['diffViewerScrollHalfPageDown', 'halfPage', 1],
    ['diffViewerScrollHalfPageUp', 'halfPage', -1],
    ['diffViewerScrollDownEmacs', 'line', 1],
    ['diffViewerScrollUpEmacs', 'line', -1],
    ['diffViewerScrollToBottom', 'edge', 1],
    ['diffViewerScrollToTop', 'edge', -1]
  ];
  var smoothTargets = new WeakMap();

  function normalizeStroke(raw) {
    return {
      key: String((raw && raw.key) || '').toLowerCase(),
      command: Boolean(raw && raw.command),
      control: Boolean(raw && raw.control),
      option: Boolean(raw && raw.option),
      shift: Boolean(raw && raw.shift)
    };
  }

  function normalizeShortcut(raw) {
    if (!raw || raw.unbound === true || !raw.first) { return null; }
    return {
      first: normalizeStroke(raw.first),
      second: raw.second ? normalizeStroke(raw.second) : null
    };
  }

  function eventKey(event) {
    if (event.code === 'Space') { return 'space'; }
    return typeof event.key === 'string' ? event.key.toLowerCase() : '';
  }

  function strokeMatches(stroke, event) {
    return Boolean(stroke) &&
      event.metaKey === stroke.command &&
      event.ctrlKey === stroke.control &&
      event.altKey === stroke.option &&
      event.shiftKey === stroke.shift &&
      eventKey(event) === stroke.key;
  }

  function isEditableTarget(target) {
    var element = target && target.closest ? target : null;
    return Boolean(element && element.closest("input, textarea, select, [contenteditable='true']"));
  }

  function isNativeScrollKey(event) {
    if (event.metaKey || event.ctrlKey || event.altKey || isEditableTarget(event.target)) { return false; }
    return ['arrowdown', 'arrowup', 'pagedown', 'pageup', 'home', 'end', 'space'].indexOf(eventKey(event)) >= 0;
  }

  function viewportHeight(scroller) {
    var height = Number(scroller && scroller.clientHeight);
    if (Number.isFinite(height) && height > 0) { return height; }
    return Math.max(1, Number(global.innerHeight) || 1);
  }

  function performAction(action, scroller) {
    var motion = actionMotions.find(function(entry) { return entry[0] === action; });
    if (!motion) { return false; }
    runMotion(scroller, motion[1], motion[2]);
    return true;
  }

  function resetSmoothTarget(scroller) {
    if (scroller) { smoothTargets.delete(scroller); }
  }

  function runMotion(scroller, kind, direction) {
    if (!scroller) { return; }
    var maxScroll = Math.max(0, (Number(scroller.scrollHeight) || 0) - viewportHeight(scroller));
    if (kind === 'edge') {
      var edgeTarget = direction > 0 ? maxScroll : 0;
      smoothTargets.set(scroller, { target: edgeTarget, time: Date.now() });
      scroller.scrollTo({ top: edgeTarget, behavior: 'smooth' });
      return;
    }
    var amount = kind === 'halfPage'
      ? Math.max(80, Math.floor(viewportHeight(scroller) * 0.5))
      : 72;
    var now = Date.now();
    var previous = smoothTargets.get(scroller);
    var current = Number(scroller.scrollTop) || 0;
    var base = previous && now - previous.time < 300 ? previous.target : current;
    var target = Math.max(0, Math.min(maxScroll, base + direction * amount));
    smoothTargets.set(scroller, { target: target, time: now });
    scroller.scrollTo({ top: target, behavior: 'smooth' });
  }

  function installManualInputReset(options) {
    var target = options && options.target;
    var getScroller = options && options.getScroller;
    if (!target || typeof target.addEventListener !== 'function' || typeof getScroller !== 'function') {
      return function() {};
    }

    function clearSmoothTarget() {
      resetSmoothTarget(getScroller());
    }

    function clearForNativeScrollKey(event) {
      if (isNativeScrollKey(event)) { clearSmoothTarget(); }
    }

    target.addEventListener('keydown', clearForNativeScrollKey, true);
    target.addEventListener('wheel', clearSmoothTarget, true);
    target.addEventListener('touchstart', clearSmoothTarget, true);
    target.addEventListener('pointerdown', clearSmoothTarget, true);
    return function() {
      target.removeEventListener('keydown', clearForNativeScrollKey, true);
      target.removeEventListener('wheel', clearSmoothTarget, true);
      target.removeEventListener('touchstart', clearSmoothTarget, true);
      target.removeEventListener('pointerdown', clearSmoothTarget, true);
    };
  }

  function install(options) {
    var target = options && options.target;
    var getScroller = options && options.getScroller;
    var shortcuts = (options && options.shortcuts) || {};
    if (!target || typeof target.addEventListener !== 'function' || typeof getScroller !== 'function') {
      return function() {};
    }

    var bindings = actionMotions.map(function(entry) {
      return {
        action: entry[0],
        shortcut: normalizeShortcut(shortcuts[entry[0]]),
        kind: entry[1],
        direction: entry[2]
      };
    }).filter(function(entry) { return entry.shortcut; });
    var pending = null;
    var pendingTimer = 0;
    var disposeManualInputReset = installManualInputReset({ target: target, getScroller: getScroller });

    function clearPending() {
      pending = null;
      if (pendingTimer) {
        global.clearTimeout(pendingTimer);
        pendingTimer = 0;
      }
    }

    function listener(event) {
      if (event.defaultPrevented || isEditableTarget(event.target)) { return; }
      if (pending) {
        if (strokeMatches(pending.shortcut.second, event)) {
          event.preventDefault();
          performAction(pending.action, getScroller());
          clearPending();
          return;
        }
        clearPending();
      }
      for (var i = 0; i < bindings.length; i++) {
        var binding = bindings[i];
        if (!strokeMatches(binding.shortcut.first, event)) { continue; }
        event.preventDefault();
        if (binding.shortcut.second) {
          pending = binding;
          pendingTimer = global.setTimeout(clearPending, 700);
        } else {
          performAction(binding.action, getScroller());
        }
        return;
      }
    }

    target.addEventListener('keydown', listener);
    return function() {
      clearPending();
      target.removeEventListener('keydown', listener);
      disposeManualInputReset();
    };
  }

  global.CmuxViewerNavigation = {
    install: install,
    installManualInputReset: installManualInputReset,
    performAction: performAction,
    resetSmoothTarget: resetSmoothTarget
  };
})(globalThis);
