'use strict';

// Observe only the first proto-1 request/reply. Never retain authentication
// fields or terminal output, and never attach a data listener (which would
// change a socket consumer's flow-control mode).
function installObserver({ report, acceptsPath, onClosed }) {
  const net = require('node:net');
  const states = new WeakMap();
  const active = new Map();
  const connect = net.Socket.prototype.connect;
  const write = net.Socket.prototype.write;
  const emit = net.Socket.prototype.emit;
  const limit = 65536;
  function publish(state, action) {
    try { report({ action, job_id: state.job, attach_id: state.attachment, viewer_pid: process.pid }); } catch {}
  }
  function firstLine(state, key, chunk, consume) {
    if (state[key] === null) return;
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    const newline = bytes.indexOf(10);
    const part = newline < 0 ? bytes : bytes.subarray(0, newline);
    if (state[key].length + part.length > limit) { state[key] = null; return; }
    state[key] = Buffer.concat([state[key], part]);
    if (newline >= 0) {
      const line = state[key]; state[key] = null;
      try { consume(JSON.parse(line.toString('utf8'))); } catch {}
    }
  }
  net.Socket.prototype.connect = function (...args) {
    // Node's normalized arguments may be [options, callback] with an internal
    // symbol; Bun also uses this form for its compiled native client.
    const options = Array.isArray(args[0]) ? args[0][0] : args[0];
    const path = typeof options === 'string' ? options : options?.path;
    if (typeof path === 'string' && acceptsPath(path)) {
      states.set(this, { request: Buffer.alloc(0), reply: Buffer.alloc(0), acknowledged: false });
    }
    return Reflect.apply(connect, this, args);
  };
  net.Socket.prototype.write = function (chunk, ...rest) {
    const state = states.get(this);
    if (state) firstLine(state, 'request', chunk, request => {
      if (request.proto !== 1 || request.op !== 'attach'
          || !/^[a-zA-Z0-9_-]{1,128}$/.test(request.short ?? '')
          || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(request.attachId ?? '')) return;
      state.job = request.short;
      state.attachment = request.attachId;
    });
    return Reflect.apply(write, this, [chunk, ...rest]);
  };
  net.Socket.prototype.emit = function (event, ...args) {
    const state = states.get(this);
    if (state && event === 'data') firstLine(state, 'reply', args[0], reply => {
      if (state.attachment && reply.ok === true && reply.op === 'attach') {
        // Keep the store bounded without dropping the newest attachment: evict
        // the oldest acknowledged lease and publish its detach so its record
        // does not outlive the observation.
        if (active.size >= 32) {
          const oldest = active.keys().next().value;
          const displaced = active.get(oldest);
          if (displaced) publish(displaced, 'detached');
          active.delete(oldest);
        }
        state.acknowledged = true;
        active.set(this, state);
        publish(state, 'attached');
      }
    });
    if (state && event === 'close') {
      if (state.acknowledged) {
        // The connection owner records closure before any CLI mutation, so a
        // failed or slow detach cannot keep routing to a closed attachment.
        try { onClosed?.(state.attachment); } catch {}
        publish(state, 'detached');
      }
      active.delete(this);
      states.delete(this);
    }
    return Reflect.apply(emit, this, [event, ...args]);
  };
  const restore = () => {
    net.Socket.prototype.connect = connect;
    net.Socket.prototype.write = write;
    net.Socket.prototype.emit = emit;
  };
  restore.detachAll = () => {
    for (const state of active.values()) publish(state, 'detached');
    active.clear();
  };
  return restore;
}

function createReportQueue(deliver, options = {}) {
  const deadlineMs = options.deadlineMs ?? 5000;
  const intervalMs = options.intervalMs ?? 250;
  const now = options.now ?? Date.now;
  const schedule = options.schedule ?? ((callback, delay) => {
    const timer = setTimeout(callback, delay);
    timer.unref?.();
    return timer;
  });
  const pending = new Map();
  let timer = null;
  const retryOne = () => {
    for (const [key, entry] of [...pending]) {
      if (deliver(entry.value) || now() > entry.deadline) pending.delete(key);
      return;
    }
  };
  const arm = () => {
    if (timer || pending.size === 0) return;
    timer = schedule(() => { timer = null; retryOne(); arm(); }, intervalMs);
  };
  return {
    report(value) {
      // A closed connection cancels its queued attach: a later retry must not
      // resurrect a lease for a socket that no longer exists.
      if (value.action === 'detached') pending.delete(value.attach_id + ':attached');
      retryOne();
      if (deliver(value)) return;
      const key = value.attach_id + ':' + value.action;
      if (pending.size >= 32 && !pending.has(key)) return;
      const entry = pending.get(key) ?? { value, deadline: now() + deadlineMs };
      entry.value = value;
      pending.set(key, entry);
      arm();
    },
    flush() { retryOne(); },
    pendingCount() { return pending.size; }
  };
}

module.exports = { installObserver, createReportQueue };

// Context is captured by the managed wrapper, then removed before Claude or
// any child executes. Bun flags are likewise restored before app startup.
if (process.env.CMUX_CLAUDE_ATTACH_CONTEXT) {
  const raw = process.env.CMUX_CLAUDE_ATTACH_CONTEXT;
  delete process.env.CMUX_CLAUDE_ATTACH_CONTEXT;
  const original = process.env.CMUX_CLAUDE_ATTACH_ORIGINAL_BUN_OPTIONS;
  const present = process.env.CMUX_CLAUDE_ATTACH_BUN_OPTIONS_PRESENT === '1';
  delete process.env.CMUX_CLAUDE_ATTACH_ORIGINAL_BUN_OPTIONS;
  delete process.env.CMUX_CLAUDE_ATTACH_BUN_OPTIONS_PRESENT;
  if (present) process.env.BUN_OPTIONS = original ?? '';
  else delete process.env.BUN_OPTIONS;
  try {
    const context = JSON.parse(raw);
    const { execFileSync } = require('node:child_process');
    if (typeof context.cli === 'string' && context.cli.startsWith('/')) {
      const environment = { ...process.env, ...context.environment, CMUX_CLAUDE_PID: String(process.pid) };
      // Complete each mutation before processing the next native socket event.
      // In particular, a close must not overtake an async subscription write.
      // This runs once per attach/close, with a 500 ms ceiling, never per frame.
      // A failed mutation is confirmed by the CLI's exit status and retried by
      // a bounded asynchronous deadline. Timers do not block Claude's event
      // loop and are unref'd; after the deadline the entry is dropped and the
      // next connection event still reconciles it.
      const deliver = value => {
        try {
          execFileSync(context.cli, ['__claude-viewer', value.action],
            { env: environment, input: JSON.stringify(value), timeout: 500, stdio: ['pipe', 'ignore', 'ignore'] });
          return true;
        } catch { return false; }
      };
      const reportQueue = createReportQueue(deliver);
      const nodePath = require('node:path');
      const nodeFS = require('node:fs');
      const statePath = context.environment.CMUX_CLAUDE_HOOK_STATE_PATH
        || (context.environment.CMUX_AGENT_HOOK_STATE_DIR
          ? nodePath.join(context.environment.CMUX_AGENT_HOOK_STATE_DIR, 'claude-hook-sessions.json')
          : nodePath.join(process.env.HOME || '', '.cmuxterm', 'claude-hook-sessions.json'));
      const closedDir = nodePath.join(nodePath.dirname(statePath), 'claude-viewer-closed');
      const markClosed = attachment => {
        if (typeof attachment !== 'string' || !/^[0-9a-f-]{36}$/i.test(attachment)) return;
        attachment = attachment.toLowerCase();
        try {
          nodeFS.mkdirSync(closedDir, { recursive: true, mode: 0o700 });
          nodeFS.writeFileSync(nodePath.join(closedDir, attachment), '');
        } catch {}
      };
      const observer = installObserver({
        acceptsPath: path => new RegExp('^/(?:private/)?tmp/cc-daemon-' + process.getuid() + '/[^/]+/control\\.sock$').test(path),
        onClosed: markClosed,
        report: value => reportQueue.report(value)
      });
      process.once('exit', () => observer.detachAll());
    }
  } catch { /* A missing/unsupported integration must not stop native Claude. */ }
}
