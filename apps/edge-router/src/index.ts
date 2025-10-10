// TODO: eslint mistakenly catches regex errors in the multiline string
/* eslint-disable no-useless-escape */

// Service worker content
const SERVICE_WORKER_JS = `

function isLoopbackHostname(hostname) {
  if (!hostname) {
    return false;
  }

  if (hostname === 'localhost' || hostname === '0.0.0.0') {
    return true;
  }

  if (hostname === '::1' || hostname === '[::1]' || hostname === '::') {
    return true;
  }

  return /^127(?:\.\d{1,3}){3}$/.test(hostname);
}

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(clients.claim());
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Check if request is to localhost or a loopback IP with a port
  if (isLoopbackHostname(url.hostname) && url.port) {
    // Get the morph ID from the current page's subdomain
    const currentHost = self.location.hostname;
    const morphIdMatch = currentHost.match(/port-\\d+-(.*)\\.cmux\\.sh/);

    if (morphIdMatch) {
      const morphId = morphIdMatch[1];
      // Redirect to port-PORT-[morphid].cmux.sh
      const redirectUrl = \`https://port-\${url.port}-\${morphId}.cmux.sh\${url.pathname}\${url.search}\`;

      // Create new headers, but let the browser handle Host header
      const headers = new Headers(event.request.headers);
      // Remove headers that might cause issues with proxying
      headers.delete('Host'); // Browser will set this correctly
      headers.set('Host', 'cmux.sh');
      headers.delete('X-Forwarded-Host');
      headers.delete('X-Forwarded-For');
      headers.delete('X-Real-IP');

      // Create a completely new request to avoid any caching or DNS issues
      const newRequest = new Request(redirectUrl, {
        method: event.request.method,
        headers: headers,
        body: event.request.method !== 'GET' && event.request.method !== 'HEAD'
          ? event.request.body
          : undefined,
        mode: 'cors',
        credentials: event.request.credentials,
        redirect: 'follow',
      });

      event.respondWith(fetch(newRequest));
      return;
    }
  }

  // For all other requests, proceed normally
});`;

// Function to rewrite JavaScript code
function rewriteJavaScript(
  code: string,
  isExternalFile: boolean = false
): string {
  // Skip if it's our injected code
  if (code.includes("__CMUX_NO_REWRITE__")) {
    return code;
  }

  // For external files, we need to ensure __cmuxLocation exists first
  // since they might load before our injected script
  const prefix = isExternalFile
    ? `
// Injected by cmux proxy - ensure __cmuxLocation exists
(function() {
  if (typeof window === 'undefined') return;

  // If __cmuxLocation already exists, we're done
  if (window.__cmuxLocation && window.__cmuxLocation.href) return;

  // Create a temporary __cmuxLocation that uses real location
  // This will be replaced by our proxy once it loads
  if (!window.__cmuxLocation) {
    window.__cmuxLocation = window.location;
  }

  // Also ensure document.__cmuxLocation exists
  if (typeof document !== 'undefined' && !document.__cmuxLocation) {
    Object.defineProperty(document, '__cmuxLocation', {
      get: function() {
        return window.__cmuxLocation || window.location;
      },
      configurable: true
    });
  }
})();
`
    : "";

  // Replace various patterns of location access
  let modified = code
    // Replace window.location
    .replace(/\bwindow\.location\b/g, "window.__cmuxLocation")
    // Replace document.location
    .replace(/\bdocument\.location\b/g, "document.__cmuxLocation");

  // For external files, DON'T replace bare 'location' at all
  // It's too risky since we can't distinguish local variables from the global
  // The prefix we add ensures __cmuxLocation exists as a fallback anyway
  if (!isExternalFile) {
    // For inline scripts (in HTML), we can be more aggressive since we control them
    // But still be careful about obvious local variables
    modified = modified.replace(/\blocation\b/g, (match, offset) => {
      const before = modified.substring(Math.max(0, offset - 20), offset);
      const after = modified.substring(offset + match.length, Math.min(modified.length, offset + match.length + 10));

      // Don't replace if it's a variable declaration
      if (/\b(const|let|var)\s+$/.test(before)) return match;

      // Don't replace if it's a destructuring pattern
      if (/[{,]\s*$/.test(before) && /\s*[:},]/.test(after)) return match;

      // Don't replace if it's a function parameter
      if (/\(\s*$/.test(before) || /^\s*[,)]/.test(after)) return match;

      // Don't replace if it's a property access (preceded by .)
      if (/\.\s*$/.test(before)) return match;

      // Don't replace if it's an object property key
      if (/^\s*:/.test(after)) return match;

      // Don't replace if it's preceded by __cmux (to avoid double replacement)
      if (/__cmux$/.test(before)) return match;

      return "__cmuxLocation";
    });
  }

  // Fix any accidental double replacements
  modified = modified
    .replace(/window\.__cmux__cmuxLocation/g, "window.__cmuxLocation")
    .replace(/document\.__cmux__cmuxLocation/g, "document.__cmuxLocation")
    .replace(/__cmux__cmuxLocation/g, "__cmuxLocation");

  return prefix + modified;
}

// Strip headers that no longer match the rewritten body contents.
const REWRITTEN_RESPONSE_IGNORED_HEADERS = [
  "content-encoding",
  "content-length",
  "transfer-encoding",
  "content-md5",
  "content-digest",
  "etag",
];

function sanitizeRewrittenResponseHeaders(source: Headers): Headers {
  const headers = new Headers(source);

  for (const header of REWRITTEN_RESPONSE_IGNORED_HEADERS) {
    headers.delete(header);
  }

  return headers;
}

// Strip CSP headers that might block proxied content
function stripCSPHeaders(source: Headers): Headers {
  const headers = new Headers(source);
  headers.delete("content-security-policy");
  headers.delete("content-security-policy-report-only");
  return headers;
}

// Add permissive CORS headers
function addPermissiveCORS(headers: Headers): Headers {
  headers.set("access-control-allow-origin", "*");
  headers.set("access-control-allow-methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS, HEAD");
  headers.set("access-control-allow-headers", "*");
  headers.set("access-control-expose-headers", "*");
  headers.set("access-control-allow-credentials", "true");
  headers.set("access-control-max-age", "86400");
  return headers;
}

// HTMLRewriter for script tags (currently unused, but kept for potential future use)
// Note: We don't rewrite inline scripts because HTMLRewriter can cause encoding issues
// with special characters. Instead, we rely on our injected scripts to handle location
// interception at runtime.
type HTMLRewriterElement = {
  getAttribute(name: string): string | null;
  remove(): void;
  prepend(content: string, options?: { html?: boolean }): void;
};

class ScriptRewriter {
  element(_element: HTMLRewriterElement) {
    // Currently no-op
  }
}

// HTMLRewriter to remove CSP meta tags
class MetaCSPRewriter {
  element(element: HTMLRewriterElement) {
    const httpEquiv = element.getAttribute("http-equiv");
    if (httpEquiv?.toLowerCase() === "content-security-policy") {
      element.remove();
    }
  }
}

class HeadRewriter {
  private skipServiceWorker: boolean;

  constructor(skipServiceWorker: boolean = false) {
    this.skipServiceWorker = skipServiceWorker;
  }

  element(element: HTMLRewriterElement) {
    // Config script with localhost interceptors
    element.prepend(
      `<script data-cmux-injected="true">
// __CMUX_NO_REWRITE__ - This marker prevents this script from being rewritten
window.cmuxConfig = {
  taskRunId: "foo"
};

// Store the real location object (before any rewriting happens)
const __realLocation = window.location;

// Determine if a hostname should be treated as loopback/local
function isLoopbackHostname(hostname) {
  if (!hostname) {
    return false;
  }

  if (hostname === 'localhost' || hostname === '0.0.0.0') {
    return true;
  }

  if (hostname === '::1' || hostname === '[::1]' || hostname === '::') {
    return true;
  }

  return /^127(?:\.\d{1,3}){3}$/.test(hostname);
}

// Function to replace loopback URLs with cmux.sh proxy
function replaceLocalhostUrl(url) {
  try {
    const urlObj = new URL(url, __realLocation.href);
    if (isLoopbackHostname(urlObj.hostname) && urlObj.port) {
      const currentHost = __realLocation.hostname;
      const morphIdMatch = currentHost.match(/port-\\d+-(.*)\\.cmux\\.sh/);

      if (morphIdMatch) {
        const morphId = morphIdMatch[1];
        urlObj.protocol = 'https:';
        urlObj.hostname = \`port-\${urlObj.port}-\${morphId}.cmux.sh\`;
        urlObj.port = '';
        return urlObj.toString();
      }
    }
    return url;
  } catch {
    return url;
  }
}

// Create our proxy location object that intercepts everything
const __cmuxLocation = new Proxy({}, {
  get(target, prop) {
    // Special handling for Symbol properties
    if (prop === Symbol.toStringTag) {
      return 'Location';
    }
    if (prop === Symbol.toPrimitive) {
      return function(hint) {
        return __realLocation.href;
      };
    }

    // Handle methods that need URL rewriting
    if (prop === 'assign') {
      return function(url) {
        const newUrl = replaceLocalhostUrl(url);
        return __realLocation.assign(newUrl);
      };
    }
    if (prop === 'replace') {
      return function(url) {
        const newUrl = replaceLocalhostUrl(url);
        return __realLocation.replace(newUrl);
      };
    }
    if (prop === 'reload') {
      return function() {
        return __realLocation.reload.apply(__realLocation, arguments);
      };
    }

    // Handle toString specially
    if (prop === 'toString') {
      return function() {
        return __realLocation.toString();
      };
    }
    if (prop === 'valueOf') {
      return function() {
        return __realLocation.valueOf();
      };
    }

    // Handle all location properties - make sure they exist!
    // These are all the standard Location properties
    const locationProps = [
      'href', 'origin', 'protocol', 'host', 'hostname', 'port',
      'pathname', 'search', 'hash', 'username', 'password', 'searchParams'
    ];

    if (locationProps.includes(prop)) {
      return __realLocation[prop];
    }

    // Handle any other property access
    const value = __realLocation[prop];
    if (value !== undefined) {
      if (typeof value === 'function') {
        return value.bind(__realLocation);
      }
      return value;
    }

    // Return undefined for unknown properties
    return undefined;
  },
  set(target, prop, value) {
    if (prop === 'href') {
      const newUrl = replaceLocalhostUrl(value);
      __realLocation.href = newUrl;
      return true;
    }

    // Allow setting other properties that are settable
    const settableProps = ['hash', 'search', 'pathname', 'port', 'hostname', 'host', 'protocol'];
    if (settableProps.includes(prop)) {
      // For these, we might want to check if they result in localhost URLs
      __realLocation[prop] = value;
      return true;
    }

    // Ignore attempts to set read-only properties
    return true;
  },
  has(target, prop) {
    // Report that we have all the properties that location has
    return prop in __realLocation;
  },
  ownKeys(target) {
    // Return all keys from real location for spread operator support
    return Object.keys(__realLocation);
  },
  getOwnPropertyDescriptor(target, prop) {
    // Return descriptor from real location
    return Object.getOwnPropertyDescriptor(__realLocation, prop);
  }
});

// Create global alias for debugging and iframe access
window.__cmuxLocation = __cmuxLocation;
window.__cmuxLocationProxy = __cmuxLocation; // Store the actual proxy separately
// Don't assign window.location directly as it might cause issues

// Create a global __cmuxLocation variable for bare references
try {
  Object.defineProperty(window, '__cmuxLocation', {
    value: __cmuxLocation,
    writable: false,
    configurable: true
  });
} catch (e) {
  // Already defined, that's fine
}

// Also set on parent and top for iframe access
try {
  if (window.parent && window.parent !== window) {
    window.parent.__cmuxLocation = __cmuxLocation;
  }
} catch (e) {
  // Cross-origin, can't access
}

try {
  if (window.top && window.top !== window) {
    window.top.__cmuxLocation = __cmuxLocation;
  }
} catch (e) {
  // Cross-origin, can't access
}

// Setup for future iframes
const originalGetElementById = document.getElementById;
if (originalGetElementById) {
  document.getElementById = function(id) {
    const element = originalGetElementById.call(this, id);
    if (element && element.tagName === 'IFRAME') {
      try {
        // Try to set __cmuxLocation on the iframe's contentWindow
        if (element.contentWindow) {
          element.contentWindow.__cmuxLocation = __cmuxLocation;
        }
      } catch (e) {
        // Cross-origin or not ready
      }
    }
    return element;
  };
}

// Override document.location too
try {
  Object.defineProperty(document, 'location', {
    get() { return __cmuxLocation; },
    set(value) {
      const newUrl = replaceLocalhostUrl(value);
      __realLocation.href = newUrl;
    },
    configurable: true
  });
} catch (e) {
}

// Also set document.__cmuxLocation for compatibility
document.__cmuxLocation = __cmuxLocation;

// Try to override window.location (this often fails but worth trying)
try {
  Object.defineProperty(window, 'location', {
    get() { return __cmuxLocation; },
    set(value) {
      if (typeof value === 'string') {
        const newUrl = replaceLocalhostUrl(value);
        __realLocation.href = newUrl;
      } else {
        __realLocation = value;
      }
    },
    configurable: true
  });
} catch (e) {
  // Expected to fail in most browsers
}

// Intercept window.open
const originalOpen = window.open;
window.open = function(url, ...args) {
  const newUrl = replaceLocalhostUrl(url);
  return originalOpen.call(this, newUrl, ...args);
};

// Intercept anchor tag clicks
document.addEventListener('click', function(e) {
  const target = e.target.closest('a');
  if (target && target.href) {
    const originalHref = target.getAttribute('href');
    const newUrl = replaceLocalhostUrl(target.href);
    if (newUrl !== target.href) {
      e.preventDefault();
      window.location.href = newUrl;
    }
  }
}, true);

// Intercept form submissions
document.addEventListener('submit', function(e) {
  const form = e.target;
  if (form && form.action) {
    const newAction = replaceLocalhostUrl(form.action);
    if (newAction !== form.action) {
      form.action = newAction;
    }
  }
}, true);

// Intercept history.pushState and history.replaceState
const originalPushState = history.pushState;
history.pushState = function(state, title, url) {
  if (url) {
    const newUrl = replaceLocalhostUrl(url);
    return originalPushState.call(this, state, title, newUrl);
  }
  return originalPushState.apply(this, arguments);
};

const originalReplaceState = history.replaceState;
history.replaceState = function(state, title, url) {
  if (url) {
    const newUrl = replaceLocalhostUrl(url);
    return originalReplaceState.call(this, state, title, newUrl);
  }
  return originalReplaceState.apply(this, arguments);
};


// Monitor for dynamically added elements with onclick handlers (wait for body to exist)
function startMutationObserver() {
  if (!document.body) {
    // If body doesn't exist yet, wait and try again
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', startMutationObserver);
    }
    return;
  }

  const observer = new MutationObserver(function(mutations) {
    mutations.forEach(function(mutation) {
      if (mutation.type === 'attributes' && mutation.attributeName === 'onclick') {
        const element = mutation.target;
        const onclickStr = element.getAttribute('onclick');
        if (onclickStr && onclickStr.includes('localhost')) {
          console.warn('Detected onclick with localhost:', onclickStr);
          // Note: We can't easily intercept inline onclick, but the location interceptors above should catch it
        }
      }
    });
  });

  observer.observe(document.body, {
    attributes: true,
    attributeFilter: ['onclick'],
    subtree: true,
    childList: true
  });
}

startMutationObserver();
</script>`,
      { html: true }
    );

    // Service worker registration script (conditional)
    if (!this.skipServiceWorker) {
      element.prepend(
        `<script data-cmux-injected="true">
// __CMUX_NO_REWRITE__ - This marker prevents this script from being rewritten
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/proxy-sw.js', { scope: '/' }).catch(console.error);
}
</script>`,
        { html: true }
      );
    }
  }
}

const LOOPBACK_V4_REGEX = /^127(?:\.\d{1,3}){3}$/;

function isLoopbackHostnameValue(hostname: string | null | undefined): boolean {
  if (!hostname) {
    return false;
  }

  const normalized = hostname.toLowerCase();

  if (normalized === "localhost" || normalized === "0.0.0.0") {
    return true;
  }

  if (normalized === "::1" || normalized === "[::1]" || normalized === "::") {
    return true;
  }

  return LOOPBACK_V4_REGEX.test(normalized);
}

function rewriteLoopbackRedirect(
  response: Response,
  buildProxyHost: (port: string) => string | null
): Response {
  const location = response.headers.get("location");
  if (!location) {
    return response;
  }

  let parsed: URL;
  try {
    parsed = new URL(location);
  } catch {
    return response; // relative URL or invalid — nothing to rewrite
  }

  if (!isLoopbackHostnameValue(parsed.hostname)) {
    return response;
  }

  const port = parsed.port;
  const proxyHost = buildProxyHost(port);
  if (!proxyHost) {
    return response;
  }

  parsed.protocol = "https:";
  parsed.hostname = proxyHost;
  parsed.port = ""; // ensure host has no explicit port

  const rewritten = parsed.toString();
  if (rewritten === location) {
    return response;
  }

  const headers = new Headers(response.headers);
  headers.set("location", rewritten);

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const host = url.hostname.toLowerCase();

    // Root apex: reply with greeting
    if (host === "cmux.sh") {
      return new Response("cmux!", {
        status: 200,
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }

    const suffix = ".cmux.sh";
    if (host.endsWith(suffix)) {
      const sub = host.slice(0, -suffix.length);

      // Serve the service worker file
      if (url.pathname === "/proxy-sw.js") {
        return new Response(SERVICE_WORKER_JS, {
          headers: {
            "content-type": "application/javascript",
            "cache-control": "no-cache",
          },
        });
      }

      // Check if subdomain starts with "port-" (hacky heuristic for Morph routing)
      if (sub.startsWith("port-")) {
        // Handle OPTIONS preflight for port-39378
        if (sub.startsWith("port-39378") && request.method === "OPTIONS") {
          return new Response(null, {
            status: 204,
            headers: addPermissiveCORS(new Headers()),
          });
        }

        // Prevent infinite loops - check if we're already proxying
        const isAlreadyProxied =
          request.headers.get("X-Cmux-Proxied") === "true";
        if (isAlreadyProxied) {
          return new Response("Loop detected in proxy", { status: 508 });
        }

        // Format: port-<port>-<vmSlug> -> port-<port>-morphvm-<vmSlug>
        // Example: port-8101-j2z9smmu.cmux.sh -> port-8101-morphvm-j2z9smmu.http.cloud.morph.so
        const parts = sub.split("-");
        if (parts.length >= 3) {
          // Insert "morphvm" after the port number
          const morphId = parts.slice(2).join("-");
          const morphSubdomain = `${parts[0]}-${parts[1]}-morphvm-${morphId}`;
          const target = new URL(
            url.pathname + url.search,
            `https://${morphSubdomain}.http.cloud.morph.so`
          );

          // Add header to prevent loops
          const headers = new Headers(request.headers);
          headers.set("X-Cmux-Proxied", "true");

          const outbound = new Request(target, {
            method: request.method,
            headers: headers,
            body: request.body,
            redirect: "manual",
          });

          // WebSocket upgrades must be returned directly without modification
          const upgradeHeader = request.headers.get("Upgrade");
          if (upgradeHeader?.toLowerCase() === "websocket") {
            return fetch(outbound);
          }

          let response = await fetch(outbound);

          response = rewriteLoopbackRedirect(response, (redirectPort) => {
            if (!redirectPort || !/^\d+$/.test(redirectPort)) {
              return null;
            }
            return `port-${redirectPort}-${morphId}.cmux.sh`;
          });

          const contentType = response.headers.get("content-type") || "";
          const skipServiceWorker = sub.startsWith("port-39378");

          // Apply HTMLRewriter to HTML responses
          if (contentType.includes("text/html")) {
            let responseHeaders = stripCSPHeaders(response.headers);
            if (skipServiceWorker) {
              responseHeaders = addPermissiveCORS(responseHeaders);
            }
            const rewriter = new HTMLRewriter()
              .on("head", new HeadRewriter(skipServiceWorker))
              .on("script", new ScriptRewriter());

            // Remove CSP meta tags for port-39378
            if (skipServiceWorker) {
              rewriter.on("meta", new MetaCSPRewriter());
            }

            return rewriter.transform(
              new Response(response.body, {
                status: response.status,
                statusText: response.statusText,
                headers: responseHeaders,
              })
            );
          }

          // Rewrite JavaScript files
          if (
            contentType.includes("javascript") ||
            url.pathname.endsWith(".js")
          ) {
            const text = await response.text();
            const rewritten = rewriteJavaScript(text, true); // external files
            let sanitizedHeaders = sanitizeRewrittenResponseHeaders(response.headers);
            sanitizedHeaders = stripCSPHeaders(sanitizedHeaders);
            if (skipServiceWorker) {
              sanitizedHeaders = addPermissiveCORS(sanitizedHeaders);
            }
            return new Response(rewritten, {
              status: response.status,
              statusText: response.statusText,
              headers: sanitizedHeaders,
            });
          }

          let responseHeaders = stripCSPHeaders(response.headers);
          if (skipServiceWorker) {
            responseHeaders = addPermissiveCORS(responseHeaders);
          }
          return new Response(response.body, {
            status: response.status,
            statusText: response.statusText,
            headers: responseHeaders,
          });
        }
      }

      // Original routing logic for non-Morph subdomains
      const parts = sub.split("-").filter(Boolean);

      // Expect: <workspace...>-<port>-<vmSlug>
      if (parts.length < 3) {
        return new Response("Invalid cmux subdomain", { status: 400 });
      }

      // Prevent infinite loops
      const isAlreadyProxied = request.headers.get("X-Cmux-Proxied") === "true";
      if (isAlreadyProxied) {
        return new Response("Loop detected in proxy", { status: 508 });
      }

      const vmSlug = parts[parts.length - 1];
      const port = parts[parts.length - 2];
      const workspace = parts.slice(0, -2).join("-");

      if (!workspace) {
        return new Response("Missing workspace in subdomain", { status: 400 });
      }
      if (!/^\d+$/.test(port)) {
        return new Response("Invalid port in subdomain", { status: 400 });
      }

      const target = new URL(
        url.pathname + url.search,
        `https://${vmSlug}.vm.freestyle.sh`
      );

      // Copy headers and inject cmux internals, avoid mutating the original
      const headers = new Headers(request.headers);
      headers.set("X-Cmux-Workspace-Internal", workspace);
      headers.set("X-Cmux-Port-Internal", port);
      headers.set("X-Cmux-Proxied", "true"); // Prevent loops

      const outbound = new Request(target, {
        method: request.method,
        headers,
        body: request.body,
        // Cloudflare runtime keeps upgrades when using fetch(outbound)
        redirect: "manual",
      });

      // WebSocket upgrades must be returned directly without modification
      const upgradeHeader = request.headers.get("Upgrade");
      if (upgradeHeader?.toLowerCase() === "websocket") {
        return fetch(outbound);
      }

      let response = await fetch(outbound);

      response = rewriteLoopbackRedirect(response, (redirectPort) => {
        if (!redirectPort || !/^\d+$/.test(redirectPort)) {
          return null;
        }

        return `${workspace}-${redirectPort}-${vmSlug}.cmux.sh`;
      });

      const contentType = response.headers.get("content-type") || "";
      const skipServiceWorker = sub.startsWith("port-39378");

      // Apply HTMLRewriter to HTML responses
      if (contentType.includes("text/html")) {
        let responseHeaders = stripCSPHeaders(response.headers);
        if (skipServiceWorker) {
          responseHeaders = addPermissiveCORS(responseHeaders);
        }
        const rewriter = new HTMLRewriter()
          .on("head", new HeadRewriter(skipServiceWorker))
          .on("script", new ScriptRewriter());

        // Remove CSP meta tags for port-39378
        if (skipServiceWorker) {
          rewriter.on("meta", new MetaCSPRewriter());
        }

        return rewriter.transform(
          new Response(response.body, {
            status: response.status,
            statusText: response.statusText,
            headers: responseHeaders,
          })
        );
      }

      // Rewrite JavaScript files
      if (contentType.includes("javascript") || url.pathname.endsWith(".js")) {
        const text = await response.text();
        const rewritten = rewriteJavaScript(text, true); // external files
        let sanitizedHeaders = sanitizeRewrittenResponseHeaders(response.headers);
        sanitizedHeaders = stripCSPHeaders(sanitizedHeaders);
        if (skipServiceWorker) {
          sanitizedHeaders = addPermissiveCORS(sanitizedHeaders);
        }
        return new Response(rewritten, {
          status: response.status,
          statusText: response.statusText,
          headers: sanitizedHeaders,
        });
      }

      let responseHeaders = stripCSPHeaders(response.headers);
      if (skipServiceWorker) {
        responseHeaders = addPermissiveCORS(responseHeaders);
      }
      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers: responseHeaders,
      });
    }

    // Not our domain — pass-through or block; pass-through by default
    return fetch(request);
  },
};
