// mobile markdown renderer: marked (GFM) + temml (TeX to MathML) + highlight.js.
(function () {
  function escapeHTML(s) {
    return s.replace(/[&<>"']/g, function (c) { return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]; });
  }
  function tex(source, display) {
    try { return temml.renderToString(source, { displayMode: display, throwOnError: false }); }
    catch (e) { return '<code>' + escapeHTML(source) + '</code>'; }
  }
  var mathBlock = {
    name: 'mathBlock', level: 'block',
    start: function (src) { var m = src.match(/\$\$|\\\[/); return m ? m.index : undefined; },
    tokenizer: function (src) {
      var m = /^\$\$([\s\S]+?)\$\$/.exec(src) || /^\\\[([\s\S]+?)\\\]/.exec(src);
      if (m) return { type: 'mathBlock', raw: m[0], text: m[1].trim() };
    },
    renderer: function (t) { return '<div class="math-block">' + tex(t.text, true) + '</div>'; }
  };
  var mathInline = {
    name: 'mathInline', level: 'inline',
    start: function (src) { var m = src.match(/\$|\\\(/); return m ? m.index : undefined; },
    tokenizer: function (src) {
      var m = /^\$(?!\s)([^$\n]+?)(?<!\s)\$(?![\w$])/.exec(src) || /^\\\(([\s\S]+?)\\\)/.exec(src);
      if (m) return { type: 'mathInline', raw: m[0], text: m[1] };
    },
    renderer: function (t) { return tex(t.text, false); }
  };
  function diffHTML(text) {
    return text.split('\n').map(function (line) {
      var cls = '';
      if (/^(\+\+\+|---|diff |index )/.test(line)) cls = 'd-meta';
      else if (line.indexOf('@@') === 0) cls = 'd-hunk';
      else if (line[0] === '+') cls = 'd-add';
      else if (line[0] === '-') cls = 'd-del';
      return cls ? '<span class="' + cls + '">' + escapeHTML(line) + '</span>' : escapeHTML(line);
    }).join('\n');
  }
  var names = { swift: 'Swift', py: 'Python', python: 'Python', ts: 'TypeScript', js: 'JavaScript', rs: 'Rust', rust: 'Rust', sh: 'Bash', bash: 'Bash', diff: 'Diff', json: 'JSON' };
  marked.use({ gfm: true, breaks: false, extensions: [mathBlock, mathInline] });
  marked.use({
    renderer: {
      code: function (token) {
        var lang = (token.lang || '').split(/\s/)[0].toLowerCase();
        var body;
        if (lang === 'diff') body = diffHTML(token.text);
        else if (lang && hljs.getLanguage(lang)) body = hljs.highlight(token.text, { language: lang, ignoreIllegals: true }).value;
        else body = escapeHTML(token.text);
        var label = names[lang] || (lang ? lang.charAt(0).toUpperCase() + lang.slice(1) : 'Code');
        return '<div class="code"><div class="code-h">' + escapeHTML(label) + '</div><pre><code class="hljs">' + body + '</code></pre></div>';
      },
      table: function (token) {
        var self = this;
        function cells(row, tag) {
          return '<tr>' + row.map(function (c, i) {
            var align = token.align[i] ? ' style="text-align:' + token.align[i] + '"' : '';
            return '<' + tag + align + '>' + self.parser.parseInline(c.tokens) + '</' + tag + '>';
          }).join('') + '</tr>';
        }
        return '<div class="table-wrap"><table><thead>' + cells(token.header, 'th') + '</thead><tbody>' +
          token.rows.map(function (r) { return cells(r, 'td'); }).join('') + '</tbody></table></div>';
      }
    }
  });

  var content = null;
  var lastHeight = -1;
  function height() { return Math.ceil(content.getBoundingClientRect().height); }
  function post() {
    var h = height();
    if (h === lastHeight) return;
    lastHeight = h;
    try { window.webkit.messageHandlers.cmuxMobile.postMessage({ type: 'height', height: h }); } catch (e) {}
  }
  // Renders and returns the laid-out height synchronously (used for measuring too).
  window.cmuxMobileRender = function (markdown, compact) {
    document.body.className = compact ? 'compact' : '';
    content.innerHTML = markdown ? marked.parse(markdown) : '';
    fitMath();
    markScrollers();
    lastHeight = -1;
    var h = height();
    post();
    return h;
  };
  // Display math wider than the column scales down to fit (the views are not scrollable).
  function fitMath() {
    var blocks = content.querySelectorAll('.math-block');
    for (var i = 0; i < blocks.length; i++) {
      var b = blocks[i], m = b.firstElementChild;
      if (!m) continue;
      var w = m.getBoundingClientRect().width, avail = b.clientWidth;
      if (w > avail && avail > 0) { m.style.fontSize = Math.max(0.55, avail / w) * 100 + '%'; }
    }
  }
  // Code and tables wider than the column scroll sideways; `.more` shows the trailing fade.
  function updateMore(el) {
    el.classList.toggle('more', el.scrollLeft + el.clientWidth < el.scrollWidth - 1);
  }
  function markScrollers() {
    var els = content.querySelectorAll('.code pre, .table-wrap');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      updateMore(el);
      if (!el.dataset.cmuxMobileScroll) {
        el.dataset.cmuxMobileScroll = '1';
        el.addEventListener('scroll', function (e) { updateMore(e.currentTarget); }, { passive: true });
      }
    }
  }
  window.cmuxMobileHeight = function () { return height(); };
  // A tap anywhere but a link opens the event (the host view forwards it).
  document.addEventListener('click', function (e) {
    if (e.target.closest && e.target.closest('a')) return;
    try { window.webkit.messageHandlers.cmuxMobile.postMessage({ type: 'tap' }); } catch (err) {}
  });
  window.addEventListener('resize', function () { if (content) markScrollers(); });
  document.addEventListener('DOMContentLoaded', function () {
    content = document.getElementById('content');
    new ResizeObserver(post).observe(content);
    try { window.webkit.messageHandlers.cmuxMobile.postMessage({ type: 'ready' }); } catch (e) {}
  });
})();
