// Shared allowlist sanitizer for markdown rendered into privileged WebViews.
//
// Used by the markdown viewer shell (inlined into shell.html as a classic
// script) and by the agent-session renderers (bundled through an ES import).
//
// Contract:
// - Untrusted HTML is parsed only inside an inert document that has no
//   browsing context, so nothing in it can run or fetch while it is parsed.
// - The output is built node by node in the target document from an explicit
//   element and attribute allowlist. Comments, processing instructions, and
//   every element outside the allowlist are dropped together with their whole
//   subtree, never unwrapped.
// - Callers insert the returned DocumentFragment directly. The sanitized tree
//   is never serialized and re-parsed into a live document, so parser
//   differentials (raw-text elements, scripting-dependent elements, foreign
//   content) cannot turn attribute or text data back into markup.
//
// Keep this file free of template placeholders and closing script tags: the
// macOS and iOS hosts splice it verbatim into the shell template.
(function(global) {
  'use strict';

  var HTML_NS = 'http://www.w3.org/1999/xhtml';
  var SVG_NS = 'http://www.w3.org/2000/svg';
  var XLINK_NS = 'http://www.w3.org/1999/xlink';

  // Elements no profile may allow. Raw-text and RCDATA elements, elements
  // whose parsing depends on the scripting flag, inert containers, plugin and
  // frame hosts, form controls, and SVG/SMIL animation all stay out even if a
  // profile names them by mistake. SVG <style> and <title> are not raw text in
  // foreign content and are handled explicitly, so they are absent here.
  var FORBIDDEN_SVG = toLowerSet([
    'script', 'noscript', 'noembed', 'noframes', 'xmp', 'plaintext', 'iframe',
    'frame', 'frameset', 'object', 'embed', 'applet', 'param', 'template',
    'textarea', 'title', 'base', 'link', 'meta', 'form', 'button', 'select',
    'option', 'optgroup', 'datalist', 'output', 'keygen', 'portal', 'slot',
    'audio', 'video', 'source', 'track', 'picture', 'canvas', 'dialog',
    'math', 'image', 'feImage', 'animate', 'animateMotion', 'animateTransform',
    'animateColor', 'set', 'discard', 'mpath', 'handler', 'listener', 'a',
    'cursor', 'font-face-uri', 'color-profile'
  ]);
  var FORBIDDEN_HTML = toLowerSet([
    'script', 'noscript', 'noembed', 'noframes', 'xmp', 'plaintext', 'iframe',
    'frame', 'frameset', 'object', 'embed', 'applet', 'param', 'template',
    'textarea', 'title', 'base', 'link', 'meta', 'form', 'button', 'select',
    'option', 'optgroup', 'datalist', 'output', 'keygen', 'portal', 'slot',
    'audio', 'video', 'source', 'track', 'picture', 'canvas', 'dialog',
    'style', 'svg', 'math', 'image'
  ]);

  var URL_ATTRIBUTES = toLowerSet([
    'href', 'src', 'xlink:href', 'action', 'formaction', 'poster', 'background',
    'cite', 'longdesc', 'lowsrc', 'dynsrc', 'srcset', 'data', 'codebase', 'ping'
  ]);

  // Elements that markdown and GitHub-style READMEs legitimately produce.
  var MARKDOWN_HTML = {
    a: ['href', 'title'],
    abbr: ['title'],
    b: [], i: [], em: [], strong: [], s: [], del: [], ins: [], u: [], mark: [],
    small: [], sub: [], sup: [], kbd: [], samp: [], 'var': [], code: [],
    cite: [], dfn: [], q: [], span: [], br: [], hr: [], wbr: [],
    div: ['align'], p: ['align'],
    blockquote: [], pre: [],
    ul: [], ol: ['start', 'reversed', 'type'], li: ['value'],
    dl: [], dt: [], dd: [],
    figure: [], figcaption: [], ruby: [], rt: [], rp: [],
    details: ['open'], summary: [],
    h1: ['id', 'align'], h2: ['id', 'align'], h3: ['id', 'align'],
    h4: ['id', 'align'], h5: ['id', 'align'], h6: ['id', 'align'],
    table: ['align'], caption: [], thead: [], tbody: [], tfoot: [],
    tr: ['align'], th: ['align', 'colspan', 'rowspan', 'scope'],
    td: ['align', 'colspan', 'rowspan'],
    img: ['src', 'alt', 'title', 'width', 'height', 'align'],
    input: ['type', 'checked', 'disabled']
  };
  var MARKDOWN_GLOBAL_ATTRIBUTES = ['title', 'lang', 'dir', 'class'];

  // HTML allowed inside SVG foreignObject labels (Mermaid htmlLabels).
  var DIAGRAM_LABEL_HTML = {
    div: [], span: [], p: [], br: [], b: [], i: [], em: [], strong: [],
    code: [], s: [], del: [], u: [], sub: [], sup: [], small: [],
    ul: [], ol: [], li: [], table: [], thead: [], tbody: [], tr: [], th: [], td: []
  };
  var DIAGRAM_LABEL_GLOBAL_ATTRIBUTES = ['class', 'style', 'id', 'lang', 'dir', 'title'];

  var DIAGRAM_SVG_ELEMENTS = [
    'svg', 'g', 'defs', 'desc', 'title', 'symbol', 'use', 'path', 'rect',
    'circle', 'ellipse', 'line', 'polyline', 'polygon', 'text', 'tspan',
    'textPath', 'marker', 'linearGradient', 'radialGradient', 'stop', 'pattern',
    'clipPath', 'mask', 'filter', 'feBlend', 'feColorMatrix',
    'feComponentTransfer', 'feComposite', 'feDropShadow', 'feFlood', 'feFuncA',
    'feFuncB', 'feFuncG', 'feFuncR', 'feGaussianBlur', 'feMerge', 'feMergeNode',
    'feMorphology', 'feOffset', 'foreignObject', 'style'
  ];
  var DIAGRAM_SVG_ATTRIBUTES = [
    'id', 'class', 'style', 'transform', 'transform-origin', 'd', 'x', 'y',
    'x1', 'x2', 'y1', 'y2', 'cx', 'cy', 'r', 'rx', 'ry', 'fx', 'fy', 'width',
    'height', 'viewBox', 'preserveAspectRatio', 'points', 'pathLength', 'fill',
    'fill-opacity', 'fill-rule', 'stroke', 'stroke-width', 'stroke-opacity',
    'stroke-dasharray', 'stroke-dashoffset', 'stroke-linecap',
    'stroke-linejoin', 'stroke-miterlimit', 'opacity', 'color', 'display',
    'visibility', 'overflow', 'clip-path', 'clip-rule', 'clipPathUnits', 'mask',
    'maskUnits', 'maskContentUnits', 'filter', 'filterUnits', 'primitiveUnits',
    'marker-start', 'marker-mid', 'marker-end', 'markerWidth', 'markerHeight',
    'markerUnits', 'refX', 'refY', 'orient', 'font-family', 'font-size',
    'font-style', 'font-weight', 'font-variant', 'letter-spacing',
    'word-spacing', 'text-anchor', 'text-decoration', 'dominant-baseline',
    'alignment-baseline', 'baseline-shift', 'writing-mode', 'direction',
    'unicode-bidi', 'dx', 'dy', 'rotate', 'textLength', 'lengthAdjust',
    'startOffset', 'offset', 'stop-color', 'stop-opacity', 'gradientUnits',
    'gradientTransform', 'spreadMethod', 'patternUnits', 'patternContentUnits',
    'patternTransform', 'href', 'xlink:href', 'role', 'focusable', 'version',
    'xml:space', 'in', 'in2', 'result', 'stdDeviation', 'mode', 'operator',
    'k1', 'k2', 'k3', 'k4', 'values', 'type', 'tableValues', 'slope',
    'intercept', 'amplitude', 'exponent', 'flood-color', 'flood-opacity',
    'lighting-color', 'radius', 'color-interpolation-filters',
    'shape-rendering', 'text-rendering', 'vector-effect', 'paint-order',
    'pointer-events', 'cursor', 'xml:lang', 'lang'
  ];

  function toLowerSet(names) {
    var set = Object.create(null);
    for (var i = 0; i < names.length; i++) {
      set[String(names[i]).toLowerCase()] = true;
    }
    return set;
  }

  function compactLower(value) {
    var raw = String(value == null ? '' : value);
    var out = '';
    for (var i = 0; i < raw.length; i++) {
      var code = raw.charCodeAt(i);
      if (code <= 32 || code === 127) { continue; }
      out += raw.charAt(i).toLowerCase();
    }
    return out;
  }

  // True when every url() reference points into the same document.
  function hasOnlyFragmentURLReferences(value) {
    var re = /url\s*\(/gi;
    var match;
    while ((match = re.exec(value)) !== null) {
      var rest = value.slice(match.index);
      if (!/^url\s*\(\s*(['"]?)#[\w.:-]*\1\s*\)/i.test(rest)) {
        return false;
      }
    }
    return true;
  }

  // Returns CSS text that cannot fetch, import, or execute, or null.
  function sanitizeCSS(text) {
    var raw = String(text == null ? '' : text);
    if (raw.indexOf('\\') >= 0) { return null; }
    if (/\/\*(?![\s\S]*?\*\/)/.test(raw)) { return null; }
    var stripped = raw.replace(/\/\*[\s\S]*?\*\//g, '');
    var compact = compactLower(stripped);
    if (
      compact.indexOf('@import') >= 0 ||
      compact.indexOf('@font-face') >= 0 ||
      compact.indexOf('expression(') >= 0 ||
      compact.indexOf('javascript:') >= 0 ||
      compact.indexOf('vbscript:') >= 0 ||
      compact.indexOf('-moz-binding') >= 0 ||
      compact.indexOf('behavior:') >= 0 ||
      compact.indexOf('image-set(') >= 0 ||
      compact.indexOf('cross-fade(') >= 0 ||
      compact.indexOf('element(') >= 0 ||
      /(^|[^a-z0-9-])image\(/.test(compact) ||
      compact.indexOf('src(') >= 0
    ) {
      return null;
    }
    if (!hasOnlyFragmentURLReferences(stripped)) { return null; }
    return raw;
  }

  // Non-URL attribute values must not smuggle fetches or script either
  // (SVG presentation attributes accept url(), for example).
  function isSafePlainAttributeValue(value) {
    var raw = String(value == null ? '' : value);
    var compact = compactLower(raw);
    if (
      compact.indexOf('javascript:') >= 0 ||
      compact.indexOf('vbscript:') >= 0 ||
      compact.indexOf('expression(') >= 0
    ) {
      return false;
    }
    if (compact.indexOf('url(') >= 0 && !hasOnlyFragmentURLReferences(raw)) {
      return false;
    }
    return true;
  }

  function isFragmentReference(value) {
    return /^#[^\s'"()<>\\]*$/.test(String(value == null ? '' : value).trim());
  }

  var MARKDOWN_CLASS_TOKEN = /^(?:hljs(?:-[\w-]+)?|[a-z][a-z0-9]*_|language-[\w+#.-]+|cmux-(?:mermaid|vega|source|frontmatter))$/;
  var DIAGRAM_CLASS_TOKEN = /^[A-Za-z_][\w-]*$/;

  function filterClassTokens(value, pattern) {
    var tokens = String(value == null ? '' : value).split(/\s+/);
    var kept = [];
    for (var i = 0; i < tokens.length; i++) {
      var token = tokens[i];
      if (token && pattern.test(token) && token.indexOf('cmux-remote-') !== 0) {
        kept.push(token);
      }
    }
    return kept.join(' ');
  }

  function buildHTMLAllowlist(elements, globalAttributes) {
    var map = Object.create(null);
    var globals = toLowerSet(globalAttributes || []);
    Object.keys(elements || {}).forEach(function(tag) {
      var lower = tag.toLowerCase();
      if (FORBIDDEN_HTML[lower]) { return; }
      var attrs = Object.create(null);
      Object.keys(globals).forEach(function(name) { attrs[name] = true; });
      (elements[tag] || []).forEach(function(name) { attrs[String(name).toLowerCase()] = true; });
      map[lower] = attrs;
    });
    return map;
  }

  function buildCanonicalMap(names, forbidden) {
    var map = Object.create(null);
    for (var i = 0; i < names.length; i++) {
      var lower = String(names[i]).toLowerCase();
      if (forbidden && forbidden[lower]) { continue; }
      map[lower] = names[i];
    }
    return map;
  }

  // Builds a sanitizer profile.
  //   html:             { tag: [attributes] } allowed in the HTML namespace
  //   htmlGlobalAttributes: attributes allowed on every allowed HTML element
  //   svgElements / svgAttributes: SVG allowlists (omit to drop all SVG)
  //   allowStyle:       allow sanitized `style` attributes and SVG <style>
  //   classToken:       RegExp each class token must match
  //   url(ctx):         returns the value to keep for a URL attribute, or null.
  //                     ctx = { namespace, tag, name, value }
  //   element(source, clean): optional post hook; return false to drop.
  //   inlineSVGAsImage: render each top-level inline <svg> as an <img> with a
  //                     data: URL instead of dropping it. WebKit draws SVG in
  //                     image context with scripts, links, external loads,
  //                     and interaction disabled, so the markup stays inert.
  function createProfile(spec) {
    spec = spec || {};
    return {
      html: buildHTMLAllowlist(spec.html, spec.htmlGlobalAttributes),
      svgElements: spec.svgElements ? buildCanonicalMap(spec.svgElements, FORBIDDEN_SVG) : null,
      svgAttributes: spec.svgAttributes ? buildCanonicalMap(spec.svgAttributes, null) : null,
      allowStyle: spec.allowStyle === true,
      classToken: spec.classToken || MARKDOWN_CLASS_TOKEN,
      url: typeof spec.url === 'function' ? spec.url : function() { return null; },
      element: typeof spec.element === 'function' ? spec.element : null,
      inlineSVGAsImage: spec.inlineSVGAsImage === true
    };
  }

  var MAX_INLINE_SVG_IMAGE_BYTES = 512 * 1024;

  function utf8Base64(text) {
    var bytes = new TextEncoder().encode(text);
    var binary = '';
    for (var i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return global.btoa(binary);
  }

  // Serializes an inert <svg> subtree as standalone XML and wraps it in an
  // <img>. Image context is what keeps it inert; nothing here filters SVG.
  function inlineSVGImage(source, doc) {
    var Serializer = global.XMLSerializer;
    if (!Serializer || typeof global.btoa !== 'function' || typeof TextEncoder === 'undefined') {
      return null;
    }
    var xml = new Serializer().serializeToString(source);
    if (xml.length > MAX_INLINE_SVG_IMAGE_BYTES) { return null; }
    var img = doc.createElement('img');
    img.setAttribute('src', 'data:image/svg+xml;base64,' + utf8Base64(xml));
    img.setAttribute('alt', '');
    img.setAttribute('class', 'cmux-inline-svg');
    return img;
  }

  function parseInert(html, targetDocument) {
    var inertDocument = targetDocument.implementation.createHTMLDocument('');
    var template = inertDocument.createElement('template');
    template.innerHTML = String(html == null ? '' : html);
    return template.content;
  }

  function sanitizedAttributeValue(profile, namespace, tag, name, lower, value) {
    if (lower.indexOf('on') === 0) { return null; }
    if (lower.indexOf('data-cmux-') === 0) { return null; }
    if (URL_ATTRIBUTES[lower]) {
      if (namespace === SVG_NS) {
        return (lower === 'href' || lower === 'xlink:href') && isFragmentReference(value)
          ? String(value).trim()
          : null;
      }
      var kept = profile.url({ namespace: namespace, tag: tag, name: lower, value: value });
      return typeof kept === 'string' ? kept : null;
    }
    if (lower === 'style') {
      return profile.allowStyle ? sanitizeCSS(value) : null;
    }
    if (lower === 'class') {
      var classes = filterClassTokens(value, profile.classToken);
      return classes ? classes : null;
    }
    return isSafePlainAttributeValue(value) ? String(value) : null;
  }

  function copyAttributes(profile, source, clean, namespace, tag, allowed) {
    var attributes = source.attributes || [];
    for (var i = 0; i < attributes.length; i++) {
      var attr = attributes[i];
      var name = String(attr.name || '');
      var lower = name.toLowerCase();
      var canonical;
      if (namespace === HTML_NS) {
        if (!allowed[lower]) { continue; }
        canonical = lower;
      } else {
        canonical = allowed[lower];
        if (!canonical && /^aria-[a-z-]+$/.test(lower)) { canonical = lower; }
        if (!canonical && /^data-[a-z0-9-]+$/.test(lower)) { canonical = lower; }
        if (!canonical) { continue; }
      }
      var value = sanitizedAttributeValue(profile, namespace, tag, name, lower, attr.value);
      if (value === null) { continue; }
      if (canonical === 'xlink:href') {
        clean.setAttributeNS(XLINK_NS, 'xlink:href', value);
      } else if (canonical === 'xml:space' || canonical === 'xml:lang') {
        clean.setAttributeNS('http://www.w3.org/XML/1998/namespace', canonical, value);
      } else {
        clean.setAttribute(canonical, value);
      }
    }
  }

  function cleanElement(profile, source, doc) {
    var namespace = source.namespaceURI;
    var localName = String(source.localName || '');
    var lower = localName.toLowerCase();
    var clean;
    if (namespace === HTML_NS) {
      if (FORBIDDEN_HTML[lower]) { return null; }
      var allowed = profile.html[lower];
      if (!allowed) { return null; }
      clean = doc.createElement(lower);
      copyAttributes(profile, source, clean, HTML_NS, lower, allowed);
    } else if (namespace === SVG_NS && !profile.svgElements && profile.inlineSVGAsImage && lower === 'svg') {
      // Returned directly: the element hook and URL policy never see it, and
      // its children are not walked (see sanitizeToFragment).
      return inlineSVGImage(source, doc);
    } else if (namespace === SVG_NS && profile.svgElements) {
      var canonical = profile.svgElements[lower];
      if (!canonical) { return null; }
      if (canonical === 'style' && !profile.allowStyle) { return null; }
      clean = doc.createElementNS(SVG_NS, canonical);
      copyAttributes(profile, source, clean, SVG_NS, canonical, profile.svgAttributes || Object.create(null));
    } else {
      return null;
    }
    if (profile.element && profile.element(source, clean) === false) {
      return null;
    }
    return clean;
  }

  // Sanitizes `html` into a DocumentFragment owned by `options.document`.
  function sanitizeToFragment(html, options) {
    options = options || {};
    var doc = options.document || global.document;
    var profile = options.profile;
    if (!doc || !profile) {
      throw new Error('CmuxMarkdownSanitizer requires a document and a profile');
    }
    var source = parseInert(html, doc);
    var output = doc.createDocumentFragment();
    var stack = [];
    pushChildren(stack, source, output);
    while (stack.length > 0) {
      var item = stack.pop();
      var node = item.node;
      var parent = item.parent;
      if (node.nodeType === 3) {
        parent.appendChild(doc.createTextNode(node.data));
        continue;
      }
      if (node.nodeType !== 1) {
        // Comments, processing instructions, CDATA, doctypes.
        continue;
      }
      var clean = cleanElement(profile, node, doc);
      if (!clean) { continue; }
      parent.appendChild(clean);
      if (node.namespaceURI === SVG_NS && clean.namespaceURI === HTML_NS) {
        // Inline SVG rendered as an image; its subtree lives in the data URL.
        continue;
      }
      if (clean.namespaceURI === SVG_NS && clean.localName === 'style') {
        var css = sanitizeCSS(node.textContent || '');
        if (css) { clean.appendChild(doc.createTextNode(css)); }
        continue;
      }
      pushChildren(stack, node, clean);
    }
    return output;
  }

  function pushChildren(stack, node, parent) {
    var children = node.childNodes || [];
    for (var i = children.length - 1; i >= 0; i--) {
      stack.push({ node: children[i], parent: parent });
    }
  }

  // Serializes a sanitized fragment for comparison or export only. The
  // string must never be assigned back into a live document.
  function serializeFragment(fragment, targetDocument) {
    var doc = targetDocument || global.document;
    var inertDocument = doc.implementation.createHTMLDocument('');
    var container = inertDocument.createElement('div');
    container.appendChild(inertDocument.importNode(fragment, true));
    return container.innerHTML;
  }

  function markdownProfile(spec) {
    spec = spec || {};
    var html = {};
    Object.keys(MARKDOWN_HTML).forEach(function(tag) {
      html[tag] = MARKDOWN_HTML[tag].slice();
    });
    (spec.removeElements || []).forEach(function(tag) { delete html[tag]; });
    var extra = spec.extraAttributes || {};
    Object.keys(extra).forEach(function(tag) {
      if (html[tag]) { html[tag] = html[tag].concat(extra[tag]); }
    });
    return createProfile({
      html: html,
      htmlGlobalAttributes: MARKDOWN_GLOBAL_ATTRIBUTES,
      classToken: MARKDOWN_CLASS_TOKEN,
      url: spec.url,
      inlineSVGAsImage: spec.inlineSVGAsImage === true,
      element: function(source, clean) {
        var tag = clean.localName;
        if (tag === 'input') {
          if (String(clean.getAttribute('type') || '').toLowerCase() !== 'checkbox') { return false; }
          clean.setAttribute('type', 'checkbox');
          clean.setAttribute('disabled', '');
        }
        if (tag === 'a') {
          clean.setAttribute('rel', 'noopener noreferrer');
        }
        return spec.element ? spec.element(source, clean) : true;
      }
    });
  }

  function diagramProfile() {
    return createProfile({
      html: DIAGRAM_LABEL_HTML,
      htmlGlobalAttributes: DIAGRAM_LABEL_GLOBAL_ATTRIBUTES,
      svgElements: DIAGRAM_SVG_ELEMENTS,
      svgAttributes: DIAGRAM_SVG_ATTRIBUTES,
      allowStyle: true,
      classToken: DIAGRAM_CLASS_TOKEN,
      url: function() { return null; }
    });
  }

  global.CmuxMarkdownSanitizer = {
    createProfile: createProfile,
    markdownProfile: markdownProfile,
    diagramProfile: diagramProfile,
    sanitizeToFragment: sanitizeToFragment,
    serializeFragment: serializeFragment,
    sanitizeCSS: sanitizeCSS
  };
})(typeof globalThis !== 'undefined' ? globalThis : this);
