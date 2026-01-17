import type {
  DOMConversionMap,
  DOMConversionOutput,
  DOMExportOutput,
  EditorConfig,
  LexicalNode,
  NodeKey,
  SerializedLexicalNode,
  Spread,
} from "lexical";

import { $applyNodeReplacement, DecoratorNode, type LexicalEditor } from "lexical";
import * as React from "react";
import { ImageNodeComponent } from "./ImageNodeComponent";

export interface ImagePayload {
  altText: string;
  src: string;
  fileName?: string;
  key?: NodeKey;
}

function convertImageElement(domNode: Node): null | DOMConversionOutput {
  if (domNode instanceof HTMLImageElement) {
    const { alt: altText, src } = domNode;
    const node = $createImageNode({ altText, src });
    return { node };
  }
  return null;
}

export type SerializedImageNode = Spread<
  {
    altText: string;
    src: string;
    fileName?: string;
  },
  SerializedLexicalNode
>;

export class ImageNode extends DecoratorNode<React.JSX.Element> {
  __src: string;
  __altText: string;
  __fileName?: string;

  static getType(): string {
    return "image";
  }

  static clone(node: ImageNode): ImageNode {
    return new ImageNode(node.__src, node.__altText, node.__fileName, node.__key);
  }

  static importJSON(serializedNode: SerializedImageNode): ImageNode {
    const { altText, src, fileName } = serializedNode;
    const node = $createImageNode({
      altText,
      src,
      fileName,
    });
    return node;
  }

  exportDOM(): DOMExportOutput {
    const element = document.createElement("img");
    element.setAttribute("src", this.__src);
    element.setAttribute("alt", this.__altText);
    if (this.__fileName) {
      element.setAttribute("data-filename", this.__fileName);
    }
    return { element };
  }

  static importDOM(): DOMConversionMap | null {
    return {
      img: () => ({
        conversion: convertImageElement,
        priority: 0,
      }),
    };
  }

  constructor(
    src: string,
    altText: string,
    fileName?: string,
    key?: NodeKey
  ) {
    super(key);
    this.__src = src;
    this.__altText = altText;
    this.__fileName = fileName;
  }

  exportJSON(): SerializedImageNode {
    return {
      altText: this.getAltText(),
      src: this.getSrc(),
      fileName: this.getFileName(),
      type: "image",
      version: 1,
    };
  }

  setWidthAndHeight(_width: number, _height: number): void {
    // This could be implemented if needed
  }

  createDOM(config: EditorConfig): HTMLElement {
    const span = document.createElement("span");
    const theme = config.theme;
    const className = theme.image;
    if (className !== undefined) {
      span.className = className;
    }
    return span;
  }

  updateDOM(): false {
    return false;
  }

  getSrc(): string {
    return this.__src;
  }

  getAltText(): string {
    return this.__altText;
  }

  getFileName(): string | undefined {
    return this.__fileName;
  }

  decorate(editor: LexicalEditor, _config: EditorConfig): React.JSX.Element {
    return (
      <ImageNodeComponent
        src={this.__src}
        altText={this.__altText}
        fileName={this.__fileName}
        nodeKey={this.__key}
        editor={editor}
      />
    );
  }
}

export function $createImageNode({
  altText,
  src,
  fileName,
  key,
}: ImagePayload): ImageNode {
  return $applyNodeReplacement(new ImageNode(src, altText, fileName, key));
}

export function $isImageNode(
  node: LexicalNode | null | undefined
): node is ImageNode {
  return node instanceof ImageNode;
}
