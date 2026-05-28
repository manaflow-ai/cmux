type MarkedLike = {
  parse(source: string, options?: Record<string, unknown>): string | Promise<string>;
};

declare global {
  interface Window {
    marked?: MarkedLike;
  }
}

const unsafeElementNames = new Set([
  "base",
  "embed",
  "form",
  "iframe",
  "link",
  "meta",
  "object",
  "script",
  "style",
]);

const urlAttributeNames = new Set(["href", "src", "xlink:href"]);

export function renderMarkdownHTML(source: string): string {
  const parser = typeof window === "undefined" ? undefined : window.marked;
  if (parser?.parse) {
    try {
      const rendered = parser.parse(escapeMarkdownRawHTML(source), {
        async: false,
        breaks: true,
        gfm: true,
      });
      if (typeof rendered === "string") {
        return sanitizeRenderedHTML(rendered);
      }
    } catch {
      return renderPlainTextHTML(source);
    }
  }
  return renderPlainTextHTML(source);
}

export function escapeMarkdownRawHTML(source: string): string {
  return source.replace(/&/g, "&amp;").replace(/</g, "&lt;");
}

export function renderPlainTextHTML(source: string): string {
  return escapeTextHTML(source).replace(/\n/g, "<br>");
}

function escapeTextHTML(source: string): string {
  return source
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function sanitizeRenderedHTML(html: string): string {
  if (typeof document === "undefined") {
    return html;
  }
  const template = document.createElement("template");
  template.innerHTML = html;

  for (const element of Array.from(template.content.querySelectorAll("*"))) {
    if (unsafeElementNames.has(element.localName)) {
      element.remove();
      continue;
    }

    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      if (name.startsWith("on") || name === "srcdoc" || name === "style") {
        element.removeAttribute(attribute.name);
        continue;
      }
      if (urlAttributeNames.has(name) && !isSafeURL(attribute.value)) {
        element.removeAttribute(attribute.name);
      }
    }

    if (element.localName === "a") {
      element.setAttribute("rel", "noreferrer");
    }
  }

  return template.innerHTML;
}

export function isSafeURL(value: string): boolean {
  const trimmed = value.trim();
  if (trimmed.startsWith("#")) {
    return true;
  }
  if (trimmed.startsWith("/") || !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed)) {
    return false;
  }
  try {
    const url = new URL(trimmed);
    return url.protocol === "http:" || url.protocol === "https:" || url.protocol === "mailto:";
  } catch {
    return false;
  }
}
