'use strict';

// Observe only the first proto-1 request/reply. Never retain authentication
// fields or terminal output, and never attach a data listener (which would
// change a socket consumer's flow-control mode).
function installObserver({ report, acceptsPath }) {
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
      if (state.acknowledged) publish(state, 'detached');
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

module.exports = { installObserver };

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
      // A detach that misses the 500 ms budget is retained here and retried on
      // the next connection event, one entry per event. No timer and no
      // unbounded blocking are added; after three attempts the entry is
      // dropped and the CLI's live process-generation checks remain the
      // backstop.
      const pending = new Map();
      const deliver = value => {
        try {
          execFileSync(context.cli, ['__claude-viewer', value.action],
            { env: environment, input: JSON.stringify(value), timeout: 500, stdio: ['pipe', 'ignore', 'ignore'] });
          return true;
        } catch { return false; }
      };
      const flushOnePending = () => {
        for (const [key, entry] of [...pending]) {
          if (deliver(entry.value)) { pending.delete(key); return; }
          entry.attempts += 1;
          if (entry.attempts >= 3) pending.delete(key);
          return;
        }
      };
      const observer = installObserver({
        acceptsPath: path => new RegExp('^/(?:private/)?tmp/cc-daemon-' + process.getuid() + '/[^/]+/control\\.sock$').test(path),
        report: value => {
          // A synchronous removal also survives Claude's immediate process.exit
          // path. SIGKILL is covered by kernel process-generation validation.
          flushOnePending();
          if (deliver(value)) return;
          const key = value.attach_id + ':' + value.action;
          const entry = pending.get(key) ?? { value, attempts: 0 };
          entry.value = value;
          entry.attempts += 1;
          if (entry.attempts >= 3 || (pending.size >= 32 && !pending.has(key))) pending.delete(key);
          else pending.set(key, entry);
        }
      });
      process.once('exit', () => observer.detachAll());
    }
  } catch { /* A missing/unsupported integration must not stop native Claude. */ }
}
