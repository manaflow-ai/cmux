import net from "node:net";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function defaultSocketPath() {
  return process.env.CMUX_SOCKET_PATH || process.env.CMUX_SOCKET || "/tmp/cmux-debug.sock";
}

function parseEndpoint(socketPath) {
  if (socketPath.startsWith("/") || !socketPath.includes(":")) {
    return { path: socketPath };
  }
  const [host, rawPort] = socketPath.split(":");
  const port = Number(rawPort);
  if (!host || !Number.isFinite(port) || port <= 0) {
    return { path: socketPath };
  }
  const normalizedHost = host.toLowerCase() === "localhost" ? "127.0.0.1" : host;
  const relay = normalizedHost === "127.0.0.1";
  return { host: normalizedHost, port, relay };
}

function relayCredentials(endpoint) {
  const envRelayID = (process.env.CMUX_RELAY_ID || "").trim();
  const envRelayToken = (process.env.CMUX_RELAY_TOKEN || "").trim();
  if (envRelayID && /^[0-9a-fA-F]+$/.test(envRelayToken) && envRelayToken.length % 2 === 0) {
    return { relayId: envRelayID, relayToken: Buffer.from(envRelayToken, "hex") };
  }

  const authPath = path.join(os.homedir(), ".cmux", "relay", `${endpoint.port}.auth`);
  const authObject = JSON.parse(fs.readFileSync(authPath, "utf8"));
  const relayId = String(authObject.relay_id || "").trim();
  const relayTokenHex = String(authObject.relay_token || "").trim();
  if (!relayId || !/^[0-9a-fA-F]+$/.test(relayTokenHex) || relayTokenHex.length % 2 !== 0) {
    throw new Error(`Missing relay auth metadata for ${endpoint.host}:${endpoint.port}`);
  }
  return { relayId, relayToken: Buffer.from(relayTokenHex, "hex") };
}

function maybeUnwrapValue(payload) {
  if (payload && typeof payload === "object" && Object.prototype.hasOwnProperty.call(payload, "value")) {
    return payload.value;
  }
  return payload;
}

class CmuxSocketClient {
  constructor({ socketPath = defaultSocketPath(), password = process.env.CMUX_SOCKET_PASSWORD } = {}) {
    this.socketPath = socketPath;
    this.password = password || "";
    this.socket = null;
    this.connectPromise = null;
    this.buffer = "";
    this.lineWaiters = [];
    this.queuedLines = [];
    this.nextId = 1;
    this.isRelayBacked = false;
    this.relaySendChain = Promise.resolve();
  }

  async connect() {
    if (this.socket && !this.connectPromise) return;
    if (this.connectPromise) {
      await this.connectPromise;
      return;
    }

    const endpoint = parseEndpoint(this.socketPath);
    this.isRelayBacked = endpoint.relay === true;
    const socket = net.createConnection(endpoint);
    this.socket = socket;
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => this.handleData(chunk));
    socket.on("error", (error) => this.rejectPending(error));
    socket.on("close", () => {
      if (this.socket === socket) {
        this.socket = null;
        this.connectPromise = null;
        this.isRelayBacked = false;
      }
      this.rejectPending(new Error("cmux socket closed"));
    });

    const connectPromise = (async () => {
      try {
        await new Promise((resolve, reject) => {
          const cleanup = () => {
            socket.off("connect", onConnect);
            socket.off("error", onError);
            socket.off("close", onClose);
          };
          const onConnect = () => {
            cleanup();
            resolve();
          };
          const onError = (error) => {
            cleanup();
            reject(error);
          };
          const onClose = () => {
            cleanup();
            reject(new Error("cmux socket closed before connect"));
          };
          socket.once("connect", onConnect);
          socket.once("error", onError);
          socket.once("close", onClose);
        });
        if (this.isRelayBacked) {
          await this.authenticateRelay(endpoint);
        }
        if (this.password && !this.isRelayBacked) {
          const response = await this.sendLineOnConnectedSocket(`auth ${this.password}`);
          if (response.startsWith("ERROR:") && !response.includes("Unknown command 'auth'")) {
            throw new Error(response);
          }
        }
      } catch (error) {
        if (this.socket === socket) {
          this.close();
        }
        throw error;
      } finally {
        if (this.connectPromise === connectPromise) {
          this.connectPromise = null;
        }
      }
    })();
    this.connectPromise = connectPromise;
    await connectPromise;
  }

  close() {
    this.socket?.destroy();
    this.socket = null;
    this.connectPromise = null;
    this.isRelayBacked = false;
    this.buffer = "";
    this.queuedLines = [];
  }

  handleData(chunk) {
    this.buffer += chunk;
    while (true) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      const waiter = this.lineWaiters.shift();
      if (waiter) {
        waiter.resolve(line);
      } else {
        this.queuedLines.push(line);
      }
    }
  }

  rejectPending(error) {
    const waiters = this.lineWaiters.splice(0);
    for (const item of waiters) item.reject(error);
  }

  async sendLine(line) {
    const endpoint = parseEndpoint(this.socketPath);
    if (endpoint.relay) {
      const send = () => this.sendLineOnOpenConnection(line);
      const next = this.relaySendChain.catch(() => undefined).then(send);
      this.relaySendChain = next.catch(() => undefined);
      return await next;
    }
    return await this.sendLineOnOpenConnection(line);
  }

  async sendLineOnOpenConnection(line) {
    await this.connect();
    const relayBacked = this.isRelayBacked;
    try {
      return await this.sendLineOnConnectedSocket(line);
    } finally {
      if (relayBacked) {
        this.close();
      }
    }
  }

  async sendLineOnConnectedSocket(line) {
    const { promise, waiter } = this.readLineWaiter();
    const rejectWaiter = (error) => {
      if (waiter) {
        const index = this.lineWaiters.indexOf(waiter);
        if (index >= 0) this.lineWaiters.splice(index, 1);
      }
      waiter?.reject(error);
    };
    try {
      this.socket.write(`${line}\n`, "utf8", (error) => {
        if (error) rejectWaiter(error);
      });
    } catch (error) {
      rejectWaiter(error);
    }
    return await promise;
  }

  readLine() {
    return this.readLineWaiter().promise;
  }

  readLineWaiter() {
    if (this.queuedLines.length > 0) {
      return { promise: Promise.resolve(this.queuedLines.shift()), waiter: null };
    }
    let waiter = null;
    const promise = new Promise((resolve, reject) => {
      waiter = { resolve, reject };
      this.lineWaiters.push(waiter);
    });
    return { promise, waiter };
  }

  async authenticateRelay(endpoint) {
    const credentials = relayCredentials(endpoint);
    const challengeLine = await this.readLine();
    const challenge = JSON.parse(challengeLine);
    if (
      challenge.protocol !== "cmux-relay-auth" ||
      !Number.isInteger(challenge.version) ||
      challenge.relay_id !== credentials.relayId ||
      !challenge.nonce
    ) {
      throw new Error("Invalid relay authentication challenge");
    }
    const authMessage = `relay_id=${credentials.relayId}\nnonce=${challenge.nonce}\nversion=${challenge.version}`;
    const mac = crypto.createHmac("sha256", credentials.relayToken).update(authMessage).digest("hex");
    const authResponse = JSON.parse(
      await this.sendLineOnConnectedSocket(JSON.stringify({ relay_id: credentials.relayId, mac }))
    );
    if (authResponse.ok !== true) {
      throw new Error("Relay authentication failed");
    }
  }

  async call(method, params = {}) {
    const id = this.nextId++;
    const responseLine = await this.sendLine(JSON.stringify({ id, method, params }));
    if (responseLine.startsWith("ERROR:")) {
      throw new Error(responseLine);
    }
    const response = JSON.parse(responseLine);
    if (response.ok) {
      return response.result ?? {};
    }
    const error = response.error || {};
    const code = error.code || "error";
    const message = error.message || "cmux browser call failed";
    const wrapped = new Error(`${code}: ${message}`);
    wrapped.code = code;
    wrapped.details = error;
    throw wrapped;
  }
}

class CmuxBrowser {
  constructor(client) {
    this.client = client;
    this.tabs = new CmuxTabs(client);
  }
}

class CmuxTabs {
  constructor(client) {
    this.client = client;
  }

  async new(options = {}) {
    const result = await this.client.call("browser.open_split", {
      url: options.url || "about:blank",
      workspace_id: options.workspaceId,
      window_id: options.windowId,
      focus: options.focus ?? false,
    });
    return new CmuxTab(this.client, result.surface_id);
  }

  async current(options = {}) {
    let surfaceId = options.surfaceId || process.env.CMUX_REPL_SURFACE_ID || "";
    if (!surfaceId) {
      const result = await this.client.call("browser.open_split", {
        url: options.url || "about:blank",
        focus: false,
      });
      surfaceId = result.surface_id;
      return new CmuxTab(this.client, surfaceId);
    }
    const tab = new CmuxTab(this.client, surfaceId);
    if (options.url) {
      await tab.goto(options.url);
    }
    return tab;
  }
}

class CmuxTab {
  constructor(client, surfaceId) {
    this.client = client;
    this.surfaceId = surfaceId;
    this.playwright = new CmuxPlaywrightPage(client, surfaceId);
    this.page = this.playwright;
  }

  async goto(url, options = {}) {
    return await this.playwright.goto(url, options);
  }

  async evaluate(script, arg) {
    return await this.playwright.evaluate(script, arg);
  }

  locator(selector) {
    return this.playwright.locator(selector);
  }

  async close() {
    return await this.client.call("surface.close", { surface_id: this.surfaceId });
  }
}

class CmuxPlaywrightPage {
  constructor(client, surfaceId) {
    this.client = client;
    this.surfaceId = surfaceId;
  }

  locator(selector) {
    return new CmuxLocator(this.client, this.surfaceId, selector);
  }

  async goto(url, options = {}) {
    const result = await this.client.call("browser.navigate", {
      surface_id: this.surfaceId,
      url,
      snapshot_after: false,
    });
    if (options.waitUntil !== false && options.waitUntil !== "commit") {
      await this.waitForLoadState(options.waitUntil || "complete", { timeout: options.timeout });
    }
    return result;
  }

  async evaluate(script, arg) {
    const source = typeof script === "function"
      ? `(${script.toString()})(${JSON.stringify(arg)})`
      : String(script);
    const result = await this.client.call("browser.eval", {
      surface_id: this.surfaceId,
      script: source,
    });
    return maybeUnwrapValue(result);
  }

  async screenshot(options = {}) {
    return await this.client.call("browser.screenshot", {
      surface_id: this.surfaceId,
      path: options.path,
    });
  }

  async waitForLoadState(state = "complete", options = {}) {
    return await this.client.call("browser.wait", {
      surface_id: this.surfaceId,
      load_state: state,
      timeout_ms: options.timeout,
    });
  }

  async title() {
    const result = await this.client.call("browser.get.title", {
      surface_id: this.surfaceId,
    });
    return typeof result.title === "string" ? result.title : maybeUnwrapValue(result);
  }

  async content() {
    return maybeUnwrapValue(await this.client.call("browser.get.html", {
      surface_id: this.surfaceId,
      selector: "html",
    }));
  }

  async moveCursor(x, y, options = {}) {
    return await this.client.call("browser.cursor.set", {
      surface_id: this.surfaceId,
      x,
      y,
      animate: options.animate ?? true,
      viewport_width: options.viewportWidth,
      viewport_height: options.viewportHeight,
    });
  }

  async hideCursor() {
    return await this.client.call("browser.cursor.hide", {
      surface_id: this.surfaceId,
    });
  }
}

class CmuxLocator {
  constructor(client, surfaceId, selector) {
    this.client = client;
    this.surfaceId = surfaceId;
    this.selector = selector;
  }

  async click(options = {}) {
    await this.moveCursorToElement(options);
    return await this.client.call("browser.click", {
      surface_id: this.surfaceId,
      selector: this.selector,
    });
  }

  async dblclick(options = {}) {
    await this.moveCursorToElement(options);
    return await this.client.call("browser.dblclick", {
      surface_id: this.surfaceId,
      selector: this.selector,
    });
  }

  async hover(options = {}) {
    await this.moveCursorToElement(options);
    return await this.client.call("browser.hover", {
      surface_id: this.surfaceId,
      selector: this.selector,
    });
  }

  async fill(value, options = {}) {
    await this.moveCursorToElement(options);
    return await this.client.call("browser.fill", {
      surface_id: this.surfaceId,
      selector: this.selector,
      value: String(value),
    });
  }

  async press(key, options = {}) {
    await this.moveCursorToElement(options);
    await this.client.call("browser.focus", {
      surface_id: this.surfaceId,
      selector: this.selector,
    });
    return await this.client.call("browser.press", {
      surface_id: this.surfaceId,
      selector: this.selector,
      key,
    });
  }

  async textContent() {
    return maybeUnwrapValue(await this.client.call("browser.get.text", {
      surface_id: this.surfaceId,
      selector: this.selector,
    }));
  }

  async inputValue() {
    return maybeUnwrapValue(await this.client.call("browser.get.value", {
      surface_id: this.surfaceId,
      selector: this.selector,
    }));
  }

  async isVisible() {
    return Boolean(maybeUnwrapValue(await this.client.call("browser.is.visible", {
      surface_id: this.surfaceId,
      selector: this.selector,
    })));
  }

  async count() {
    const result = await this.client.call("browser.get.count", {
      surface_id: this.surfaceId,
      selector: this.selector,
    });
    return Number(result.count || 0);
  }

  async boundingBox() {
    return maybeUnwrapValue(await this.client.call("browser.get.box", {
      surface_id: this.surfaceId,
      selector: this.selector,
    }));
  }

  async moveCursorToElement(options = {}) {
    const box = await this.boundingBox();
    if (!box) return null;
    const x = Number(box.x || box.left || 0) + Number(box.width || 0) / 2;
    const y = Number(box.y || box.top || 0) + Number(box.height || 0) / 2;
    return await this.client.call("browser.cursor.set", {
      surface_id: this.surfaceId,
      x,
      y,
      animate: options.animate ?? true,
    });
  }
}

export async function setupCmuxBrowserRuntime(options = {}) {
  const globals = options.globals || globalThis;
  const client = new CmuxSocketClient({
    socketPath: options.socketPath || defaultSocketPath(),
    password: options.password ?? process.env.CMUX_SOCKET_PASSWORD,
  });
  await client.connect();
  const agent = {
    browsers: {
      async get(name = "cmux") {
        if (name !== "cmux") {
          throw new Error(`Unknown browser runtime: ${name}`);
        }
        return new CmuxBrowser(client);
      },
    },
  };
  globals.agent = agent;
  globals.cmuxBrowserClient = client;
  return { agent, client };
}

export { CmuxSocketClient, CmuxBrowser, CmuxTab, CmuxPlaywrightPage, CmuxLocator };
