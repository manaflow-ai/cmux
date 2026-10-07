// Adapted from playwright-core 1.57.0: lib/utils/isomorphic/locatorUtils.js and
// the escape helpers it uses from lib/utils/isomorphic/stringUtils.js. The
// functions are unchanged; only the module wrapper differs so the file runs as
// a plain script in JavaScriptCore and Node.
// Copyright (c) Microsoft Corporation. Licensed under the Apache License 2.0.
// See THIRD_PARTY_LICENSES.md. https://github.com/microsoft/playwright
(function (root) {
  "use strict";

  function escapeRegexForSelector(re) {
    if (re.unicode || re.unicodeSets)
      return String(re);
    return String(re).replace(/(^|[^\\])(\\\\)*(["'`])/g, "$1$2\\$3").replace(/>>/g, "\\>\\>");
  }
  function escapeForTextSelector(text, exact) {
    if (typeof text !== "string")
      return escapeRegexForSelector(text);
    return `${JSON.stringify(text)}${exact ? "s" : "i"}`;
  }
  function escapeForAttributeSelector(value, exact) {
    if (typeof value !== "string")
      return escapeRegexForSelector(value);
    return `"${value.replace(/\\/g, "\\\\").replace(/["]/g, '\\"')}"${exact ? "s" : "i"}`;
  }
  function getByAttributeTextSelector(attrName, text, options) {
    return `internal:attr=[${attrName}=${escapeForAttributeSelector(text, (options && options.exact) || false)}]`;
  }
  function getByTestIdSelector(testIdAttributeName, testId) {
    return `internal:testid=[${testIdAttributeName}=${escapeForAttributeSelector(testId, true)}]`;
  }
  function getByLabelSelector(text, options) {
    return "internal:label=" + escapeForTextSelector(text, !!(options && options.exact));
  }
  function getByAltTextSelector(text, options) {
    return getByAttributeTextSelector("alt", text, options);
  }
  function getByTitleSelector(text, options) {
    return getByAttributeTextSelector("title", text, options);
  }
  function getByPlaceholderSelector(text, options) {
    return getByAttributeTextSelector("placeholder", text, options);
  }
  function getByTextSelector(text, options) {
    return "internal:text=" + escapeForTextSelector(text, !!(options && options.exact));
  }
  function getByRoleSelector(role, options = {}) {
    const props = [];
    if (options.checked !== void 0)
      props.push(["checked", String(options.checked)]);
    if (options.disabled !== void 0)
      props.push(["disabled", String(options.disabled)]);
    if (options.selected !== void 0)
      props.push(["selected", String(options.selected)]);
    if (options.expanded !== void 0)
      props.push(["expanded", String(options.expanded)]);
    if (options.includeHidden !== void 0)
      props.push(["include-hidden", String(options.includeHidden)]);
    if (options.level !== void 0)
      props.push(["level", String(options.level)]);
    if (options.name !== void 0)
      props.push(["name", escapeForAttributeSelector(options.name, !!options.exact)]);
    if (options.pressed !== void 0)
      props.push(["pressed", String(options.pressed)]);
    return `internal:role=${role}${props.map(([n, v]) => `[${n}=${v}]`).join("")}`;
  }

  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  ns.locatorUtils = {
    escapeForTextSelector,
    escapeForAttributeSelector,
    getByAltTextSelector,
    getByLabelSelector,
    getByPlaceholderSelector,
    getByRoleSelector,
    getByTestIdSelector,
    getByTextSelector,
    getByTitleSelector,
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
