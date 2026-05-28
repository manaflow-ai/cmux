import"./chunks/diffs-kx78rq7q.mjs";var n5=128;function L1(){return{childIdByNameId:new Map,childIds:[],childPositionById:new Map,childVisibleChunkSums:null,totalChildSubtreeNodeCount:0,totalChildVisibleSubtreeCount:0}}function C4(){return{childIdByNameId:null,childIds:[],childPositionById:null,childVisibleChunkSums:null,totalChildSubtreeNodeCount:0,totalChildVisibleSubtreeCount:0}}function Y1(J,Q){if(Q.childIdByNameId!=null)return Q.childIdByNameId;let X=new Map;for(let Z of Q.childIds){let Y=J[Z];if(Y!=null)X.set(Y.nameId,Z)}return Q.childIdByNameId=X,X}function v1(J){if(J.childPositionById!=null)return J.childPositionById;let Q=new Map;for(let X=0;X<J.childIds.length;X++){let Z=J.childIds[X];if(Z!=null)Q.set(Z,X)}return J.childPositionById=Q,Q}function S1(J,Q){if(J.childPositionById!=null)J.childPositionById.set(Q,J.childIds.length);J.childIds.push(Q)}function b4(J,Q){if(J.childPositionById==null)return;for(let X=Q;X<J.childIds.length;X++){let Z=J.childIds[X];if(Z!=null)J.childPositionById.set(Z,X)}}function B1(J,Q){let X=0,Z=0;for(let Y of Q.childIds){let W=J[Y];if(W==null)continue;X+=W.subtreeNodeCount,Z+=W.visibleSubtreeCount}Q.totalChildSubtreeNodeCount=X,Q.totalChildVisibleSubtreeCount=Z,F1(J,Q)}function c3(J,Q,X,Z){if(J.totalChildSubtreeNodeCount+=X,J.totalChildVisibleSubtreeCount+=Z,J.childVisibleChunkSums==null||Z===0)return;let Y=v1(J).get(Q);if(Y===void 0)return;let W=Y>>5;J.childVisibleChunkSums[W]+=Z}function p3(J,Q,X){let Z=Q.childVisibleChunkSums;if(Z!=null){let W=X,q=0;for(let G of Z){if(W<G){let $=GJ(J,Q,q,W);return{...$,childVisibleIndex:X-$.localVisibleIndex}}W-=G,q+=32}throw Error(`Visible child index ${String(X)} is out of range`)}let Y=X;for(let W=0;W<Q.childIds.length;W++){let q=Q.childIds[W];if(q==null)continue;let G=J[q];if(G==null)continue;if(Y<G.visibleSubtreeCount)return{childIndex:W,childVisibleIndex:X-Y,localVisibleIndex:Y};Y-=G.visibleSubtreeCount}throw Error(`Visible child index ${String(X)} is out of range`)}function t5(J,Q,X){let Z=0,Y=Q.childVisibleChunkSums,W=0;if(Y!=null){let q=X>>5;for(let G=0;G<q;G+=1)Z+=Y[G]??0;W=q<<5}for(let q=W;q<X;q+=1){let G=Q.childIds[q];if(G==null)continue;let $=J[G];if($==null)continue;Z+=$.visibleSubtreeCount}return Z}function F1(J,Q){if(Q.childIds.length<128){Q.childVisibleChunkSums=null;return}let X=Math.ceil(Q.childIds.length/32),Z=new Int32Array(X);for(let Y=0;Y<Q.childIds.length;Y++){let W=Q.childIds[Y];if(W==null)continue;let q=J[W];if(q==null)continue;Z[Y>>5]+=q.visibleSubtreeCount}Q.childVisibleChunkSums=Z}function GJ(J,Q,X,Z){let Y=Math.min(Q.childIds.length,X+32),W=Z;for(let q=X;q<Y;q++){let G=Q.childIds[q];if(G==null)continue;let $=J[G];if($==null)continue;if(W<$.visibleSubtreeCount)return{childIndex:q,localVisibleIndex:W};W-=$.visibleSubtreeCount}throw Error(`Visible child index ${String(Z)} is out of range`)}var e5=0,R0=1,h0=1,K0=2,H1=4;function L0(J,Q,X=0){return J<<4|X<<3|Q}function E0(J){return J.depthAndFlags>>>4}function M3(J){return(J.depthAndFlags&8)>>3}function C(J){return(J.depthAndFlags&8)!==0}function J6(J){return J.depthAndFlags&7}function s(J,Q){return(J6(J)&Q)!==0}function f1(J,Q){J.depthAndFlags|=Q}function Q6(J,Q){J.depthAndFlags=L0(Q,J6(J),M3(J))}var X6=Symbol("benchmarkInstrumentation");function Z6(J,Q){if(Q==null)return J;return Object.defineProperty(J,X6,{configurable:!0,enumerable:!1,value:Q,writable:!1}),J}function _3(J){if(J==null)return null;return J[X6]??null}function T(J,Q,X){if(J==null)return X();return J.measurePhase(Q,X)}function P1(J,Q,X){if(!Number.isFinite(X)||J==null)return;J.setCounter(Q,X)}function Y6(J){return J>=48&&J<=57}function $J(J){let Q=[],X=0,Z=0;while(Z<J.length){while(Z<J.length&&!Y6(J.charCodeAt(Z)))Z+=1;if(Z>=J.length)break;if(Z>X)Q.push(J.slice(X,Z));let Y=0;while(Z<J.length&&Y6(J.charCodeAt(Z)))Y=Y*10+(J.charCodeAt(Z)-48),Z+=1;Q.push(Y),X=Z}if(X<J.length||Q.length===0)Q.push(J.slice(X));return Q}function k1(J){let Q=J.toLowerCase();return{lowerValue:Q,tokens:$J(Q)}}function UJ(J,Q){let X=Math.min(J.length,Q.length);for(let Z=0;Z<X;Z++){let Y=J[Z],W=Q[Z];if(Y===W)continue;if(typeof Y==="number"&&typeof W==="number")return Y<W?-1:1;let q=String(Y),G=String(W);if(q!==G)return q<G?-1:1}if(J.length!==Q.length)return J.length<Q.length?-1:1;return 0}function j3(J,Q){if(J.tokens.length===1&&Q.tokens.length===1&&typeof J.tokens[0]==="string"&&typeof Q.tokens[0]==="string"){if(J.lowerValue===Q.lowerValue)return 0;return J.lowerValue<Q.lowerValue?-1:1}let X=UJ(J.tokens,Q.tokens);if(X!==0)return X;if(J.lowerValue!==Q.lowerValue)return J.lowerValue<Q.lowerValue?-1:1;return 0}function W6(J,Q,X){let Z=j3(X(J),X(Q));if(Z!==0)return Z;if(J===Q)return 0;return J<Q?-1:1}function zJ(J,Q){return W6(J,Q,k1)}function h3(J,Q){if(Q!==J.segments.length-1)return R0;return J.isDirectory?R0:e5}function KJ(J,Q){let X=Math.min(J.segments.length,Q.segments.length);for(let Z=0;Z<X;Z++){let Y=J.segments[Z],W=Q.segments[Z];if(Y===W)continue;let q=h3(J,Z);if(q!==h3(Q,Z))return q===R0?-1:1;return zJ(Y,W)}if(J.segments.length!==Q.segments.length)return J.segments.length<Q.segments.length?-1:1;if(J.isDirectory===Q.isDirectory)return 0;return J.isDirectory?-1:1}function q6(J,Q){return KJ(J,Q)}function G6(J,Q,X){let Z=(W)=>{let q=X.get(W);if(q!=null)return q;let G=k1(W);return X.set(W,G),G},Y=Math.min(J.segments.length,Q.segments.length);for(let W=0;W<Y;W++){let q=J.segments[W],G=Q.segments[W];if(q===G)continue;let $=h3(J,W);if($!==h3(Q,W))return $===R0?-1:1;return W6(q,G,Z)}if(J.segments.length!==Q.segments.length)return J.segments.length<Q.segments.length?-1:1;if(J.isDirectory===Q.isDirectory)return 0;return J.isDirectory?-1:1}function O3(J,Q){let X=J.sortKeyById[Q];if(X!==void 0)return X;let Z=J.valueById[Q],Y=k1(Z);return J.sortKeyById[Q]=Y,Y}function w4(J={}){return{flattenEmptyDirectories:J.flattenEmptyDirectories!==!1,sort:J.sort??"default"}}function $6(J){let Q=J.length>0&&J.charCodeAt(J.length-1)===47,X=Q?J.length-1:J.length,Z=[],Y=0;for(let W=0;W<X;W++){if(J.charCodeAt(W)!==47)continue;Z.push(J.slice(Y,W)),Y=W+1}return Z.push(J.slice(Y,X)),{hasTrailingSlash:Q,segments:Z}}function V1(J){let{hasTrailingSlash:Q,segments:X}=$6(J);return{basename:X[X.length-1]??"",isDirectory:Q,path:J,segments:X}}function l3(J){if(J.length===0)return{requiresDirectory:!1,segments:[]};let{hasTrailingSlash:Q,segments:X}=$6(J);return{requiresDirectory:Q,segments:X}}var N4="";function d3(){let J=new Map;return J.set(N4,0),{idByValue:J,valueById:[N4],sortKeyById:[k1(N4)]}}function g0(J,Q){let X=J.idByValue.get(Q);if(X!==void 0)return X;let Z=J.valueById.length;return J.idByValue.set(Q,Z),J.valueById.push(Q),Z}function b0(J,Q){let X=J.valueById[Q];if(X===void 0)throw Error(`Unknown segment ID: ${String(Q)}`);return X}var y4=Symbol("pathStorePreparedInputKind");function K6(J,Q){return J[y4]=Q,J}function U6(J){return{basename:J.basename,depth:J.segments.length,isDirectory:J.isDirectory,path:J.path,segments:J.segments}}function A6(J,Q,X){if(X==="default")return q6(J,Q);return X(U6(J),U6(Q))}function AJ(){return{depthAndFlags:L0(0,h0|K0,R0),nameId:0,parentId:0,subtreeNodeCount:1,visibleSubtreeCount:1}}function MJ(J,Q){let X=Math.min(J.length,Q.length);for(let Z=0;Z<X;Z++)if(J[Z]!==Q[Z])return Z;return X}function z6(J){return J.isDirectory?J.segments.length:J.segments.length-1}function _J(J){return Array.isArray(J)&&J.every((Q)=>Q!=null&&typeof Q==="object"&&typeof Q.path==="string"&&Array.isArray(Q.segments)&&typeof Q.basename==="string"&&typeof Q.isDirectory==="boolean")}function jJ(J){return Array.isArray(J)&&J.every((Q)=>typeof Q==="string")}function M6(J,Q={}){return i3(J,Q).map((X)=>X.path)}function _6(J,Q={}){let X=i3(J,Q);return K6({paths:X.map((Z)=>Z.path),preparedPaths:X},"prepared")}function j6(J){let Q=J.length,X=!1;for(let Z=0;Z<Q;Z+=1){let Y=J[Z];if(Y.length>0&&Y.charCodeAt(Y.length-1)===47){X=!0;break}}return K6({paths:J,presortedPaths:J,presortedPathsContainDirectories:X},"presorted")}function O6(J){let Q=J,X=Q.preparedPaths;if(Q[y4]==="prepared"&&X!=null)return X;if(!_J(X))throw Error("preparedInput must come from PathStore.prepareInput()");return X}function L6(J){let Q=J;if(Q[y4]==="presorted"&&Q.presortedPaths!=null)return Q.presortedPaths;return jJ(Q.presortedPaths)?Q.presortedPaths:null}function B6(J){let Q=J;return typeof Q.presortedPathsContainDirectories==="boolean"?Q.presortedPathsContainDirectories:null}function i3(J,Q={}){let X=w4(Q),Z=_3(Q);P1(Z,"workload.inputFiles",J.length);let Y=T(Z,"store.preparePathEntries.parse",()=>J.map((W)=>V1(W)));return T(Z,"store.preparePathEntries.sort",()=>Y.sort((W,q)=>A6(W,q,X.sort))),Y}var s3=class{directories=new Map;directoryStack=[0];presortedDirectoryNodeIds=[];initialExpandedPathSet;createdDirectoriesAllExpanded=!1;createdDirectoryCount=0;lastPreparedPath=null;nodes=[AJ()];options;instrumentation;segmentSortKeyCache=new Map;segmentTable=d3();hasDeferredDirectoryIndexes=!1;constructor(J={}){this.instrumentation=_3(J),this.options=w4(J);let Q=J.initialExpandedPaths??null;if(Q==null||Q.length===0)this.initialExpandedPathSet=null;else{let X=new Set,Z=Q.length;for(let Y=0;Y<Z;Y+=1){let W=Q[Y],q=W.length;X.add(q>0&&W.charCodeAt(q-1)===47?W.slice(0,q-1):W)}this.initialExpandedPathSet=X,this.createdDirectoriesAllExpanded=!0}this.directories.set(0,L1())}appendPaths(J){return T(this.instrumentation,"store.builder.appendPaths.parse",()=>this.appendPreparedPaths(J.map((Q)=>V1(Q))))}appendPreparedPaths(J,Q=!0){return this.createdDirectoriesAllExpanded=!1,T(this.instrumentation,"store.builder.appendPreparedPaths",()=>{for(let X of J)this.appendPreparedPath(X,Q)}),this}appendPresortedPaths(J,Q=null){return T(this.instrumentation,"store.builder.appendPresortedPaths",()=>{if(Q===!1){this.appendPresortedFilePaths(J);return}this.createdDirectoriesAllExpanded=!1;let X=null,Z=0,Y=this.nodes,W=this.segmentTable,q=W.idByValue,G=W.valueById,$=this.directoryStack,A=0,K="",M=0;for(let U of J){if(X===U)throw Error(`Duplicate path: "${U}"`);let j=U.length>0&&U.charCodeAt(U.length-1)===47,_=j?U.length-1:U.length,F=0,k=0;if(X!=null)if(K.length>0&&U.length>K.length&&U.startsWith(K))F=M,k=K.length;else{let L=Math.min(_,X.length),B=!0;for(let H=0;H<L;H++){let w=U.charCodeAt(H);if(w!==X.charCodeAt(H)){B=!1;break}if(w===47)F++,k=H+1}if(B&&j&&L===_&&X.length>_&&X.charCodeAt(_)===47)F++,k=_+1}A=F,Z=F;let b=k,E=U.indexOf("/",b);while(E>=0&&E<_){let L=$[A];if(L===void 0)throw Error("Directory stack underflow while building the path store");Z++;let B=U.slice(b,E),H=q.get(B);if(H===void 0)H=G.length,q.set(B,H),G.push(B);let w=Y.length;Y.push({depthAndFlags:L0(Z,0,R0),nameId:H,parentId:L,subtreeNodeCount:1,visibleSubtreeCount:1}),this.recordCreatedDirectoryPath(U.slice(0,E)),A++,$[A]=w,b=E+1,E=U.indexOf("/",b)}if(j){if(b<_){let B=$[A];if(B===void 0)throw Error(`Unable to resolve directory parent for "${U}"`);Z++;let H=U.slice(b,_),w=q.get(H);if(w===void 0)w=G.length,q.set(H,w),G.push(H);let P=Y.length;Y.push({depthAndFlags:L0(Z,0,R0),nameId:w,parentId:B,subtreeNodeCount:1,visibleSubtreeCount:1}),A++,$[A]=P}let L=$[A];if(L===void 0)throw Error(`Unable to resolve directory node for "${U}"`);this.promoteDirectoryToExplicit(L,U)}else{let L=$[A];if(L===void 0)throw Error(`Unable to resolve file parent for "${U}"`);let B=U.slice(b),H=q.get(B);if(H===void 0)H=G.length,q.set(B,H),G.push(B);Y.push({depthAndFlags:L0(Z+1,0),nameId:H,parentId:L,subtreeNodeCount:1,visibleSubtreeCount:1})}if(b!==K.length)K=U.substring(0,b),M=Z;X=U}if($.length=A+1,X!=null)this.lastPreparedPath=V1(X);this.hasDeferredDirectoryIndexes=!0}),this}appendPresortedFilePaths(J){let Q=null,X=0,Z=this.nodes,Y=this.segmentTable,W=Y.idByValue,q=Y.valueById,G=this.directoryStack,$=0,A="",K=0;for(let M of J){if(Q===M)throw Error(`Duplicate path: "${M}"`);let U=M.length,j=0,_=0;if(Q!=null)if(A.length>0&&M.length>A.length&&M.startsWith(A))j=K,_=A.length;else{let B=Math.min(U,Q.length);for(let H=0;H<B;H++){let w=M.charCodeAt(H);if(w!==Q.charCodeAt(H))break;if(w===47)j++,_=H+1}}$=j,X=j;let F=_,k=M.indexOf("/",F);while(k>=0){let B=G[$];if(B===void 0)throw Error("Directory stack underflow while building the path store");X++;let H=M.slice(F,k),w=W.get(H);if(w===void 0)w=q.length,W.set(H,w),q.push(H);let P=Z.length;Z.push({depthAndFlags:L0(X,0,R0),nameId:w,parentId:B,subtreeNodeCount:1,visibleSubtreeCount:1}),this.recordCreatedDirectoryPath(M.slice(0,k)),this.presortedDirectoryNodeIds.push(P),$++,G[$]=P,F=k+1,k=M.indexOf("/",F)}let b=G[$];if(b===void 0)throw Error(`Unable to resolve file parent for "${M}"`);let E=M.slice(F),L=W.get(E);if(L===void 0)L=q.length,W.set(E,L),q.push(E);if(Z.push({depthAndFlags:L0(X+1,0),nameId:L,parentId:b,subtreeNodeCount:1,visibleSubtreeCount:1}),F!==A.length)A=M.substring(0,F),K=X;Q=M}if(G.length=$+1,Q!=null)this.lastPreparedPath=V1(Q);this.hasDeferredDirectoryIndexes=!0}finish(J={}){let Q=J.skipSubtreeCountPass===!0;if(this.hasDeferredDirectoryIndexes)T(this.instrumentation,"store.builder.buildDirectoryIndexes",()=>this.buildPresortedFinish(Q)),this.hasDeferredDirectoryIndexes=!1;else if(!Q)T(this.instrumentation,"store.builder.computeSubtreeCounts",()=>this.computeSubtreeCounts(0));return{directories:this.directories,nodes:this.nodes,options:this.options,rootId:0,segmentTable:this.segmentTable,presortedDirectoryNodeIds:this.presortedDirectoryNodeIds.length>0?this.presortedDirectoryNodeIds:null}}didMatchAllInitialExpandedPaths(){return this.createdDirectoriesAllExpanded&&this.initialExpandedPathSet!=null&&this.createdDirectoryCount===this.initialExpandedPathSet.size}appendPreparedPath(J,Q){if(this.hasDeferredDirectoryIndexes)this.buildDirectoryIndexes(),this.hasDeferredDirectoryIndexes=!1;if(this.lastPreparedPath!=null){if(J.path===this.lastPreparedPath.path)throw Error(`Duplicate path: "${J.path}"`);if(Q){if((this.options.sort==="default"?G6(this.lastPreparedPath,J,this.segmentSortKeyCache):A6(this.lastPreparedPath,J,this.options.sort))>0)throw Error(`Builder input must be sorted before appendPaths(): "${J.path}"`)}}let X=this.lastPreparedPath,Z=z6(J),Y=X==null?0:z6(X),W=X==null?0:MJ(X.segments,J.segments),q=Math.min(W,Z,Y);this.directoryStack.length=q+1;for(let $=q;$<Z;$++){let A=this.directoryStack[this.directoryStack.length-1];if(A===void 0)throw Error("Directory stack underflow while building the path store");let K=Q?this.getOrCreateDirectoryChild(A,J.segments[$]):this.createDirectoryChild(A,J.segments[$]);this.directoryStack.push(K)}if(J.isDirectory){let $=this.directoryStack[this.directoryStack.length-1];if($===void 0)throw Error(`Unable to resolve directory node for "${J.path}"`);this.promoteDirectoryToExplicit($,J.path),this.lastPreparedPath=J;return}let G=this.directoryStack[this.directoryStack.length-1];if(G===void 0)throw Error(`Unable to resolve file parent for "${J.path}"`);if(Q)this.createFileChild(G,J.basename,J.path);else this.createFileChildUnchecked(G,J.basename);this.lastPreparedPath=J}recordCreatedDirectoryPath(J){if(!this.createdDirectoriesAllExpanded||this.initialExpandedPathSet==null)return;if(this.createdDirectoryCount+=1,!this.initialExpandedPathSet.has(J))this.createdDirectoriesAllExpanded=!1}createFileChild(J,Q,X){let Z=g0(this.segmentTable,Q),Y=this.getDirectoryIndex(J),W=Y.childIdByNameId;if(W!=null){if(W.get(Z)!==void 0)throw Error(`Path collides with an existing entry: "${X}"`)}let q=this.nodes[J];if(q===void 0)throw Error(`Unknown parent node ID: ${String(J)}`);let G=this.nodes.length;if(this.nodes.push({depthAndFlags:L0(E0(q)+1,0),nameId:Z,parentId:J,subtreeNodeCount:1,visibleSubtreeCount:1}),W!=null)W.set(Z,G);return S1(Y,G),G}createFileChildUnchecked(J,Q){let X=g0(this.segmentTable,Q),Z=this.getDirectoryIndex(J),Y=this.nodes[J];if(Y===void 0)throw Error(`Unknown parent node ID: ${String(J)}`);let W=this.nodes.length;if(this.nodes.push({depthAndFlags:L0(E0(Y)+1,0),nameId:X,parentId:J,subtreeNodeCount:1,visibleSubtreeCount:1}),Z.childIdByNameId!=null)Z.childIdByNameId.set(X,W);return S1(Z,W),W}getOrCreateDirectoryChild(J,Q){let X=g0(this.segmentTable,Q),Z=this.getDirectoryIndex(J);if(Z.childIdByNameId!=null){let q=Z.childIdByNameId.get(X);if(q!==void 0){let G=this.nodes[q];if(G!=null&&!C(G))throw Error(`Path collides with an existing file while creating directory "${Q}"`);return q}}let Y=this.nodes[J];if(Y===void 0)throw Error(`Unknown parent node ID: ${String(J)}`);let W=this.nodes.length;if(this.nodes.push({depthAndFlags:L0(E0(Y)+1,0,R0),nameId:X,parentId:J,subtreeNodeCount:1,visibleSubtreeCount:1}),Z.childIdByNameId!=null)Z.childIdByNameId.set(X,W);return S1(Z,W),this.directories.set(W,L1()),W}createDirectoryChild(J,Q){let X=g0(this.segmentTable,Q),Z=this.getDirectoryIndex(J),Y=this.nodes[J];if(Y===void 0)throw Error(`Unknown parent node ID: ${String(J)}`);let W=this.nodes.length;if(this.nodes.push({depthAndFlags:L0(E0(Y)+1,0,R0),nameId:X,parentId:J,subtreeNodeCount:1,visibleSubtreeCount:1}),Z.childIdByNameId!=null)Z.childIdByNameId.set(X,W);return S1(Z,W),this.directories.set(W,L1()),W}promoteDirectoryToExplicit(J,Q){let X=this.nodes[J];if(X===void 0)throw Error(`Unknown directory node ID: ${String(J)}`);if(!C(X))throw Error(`Path is not a directory: "${Q}"`);if(s(X,h0))throw Error(`Duplicate path: "${Q}"`);f1(X,h0)}getDirectoryIndex(J){let Q=this.directories.get(J);if(Q!==void 0)return Q;throw Error(`Unknown directory child index for node ${String(J)}`)}buildPresortedFinish(J){let Q=this.nodes,X=this.directories;X.set(0,C4());let Z=-1,Y=null;for(let W=1;W<Q.length;W++){let q=Q[W];if(q==null)continue;if(C(q)){let $=C4();X.set(W,$),Z=W,Y=$}let G;if(q.parentId===Z)G=Y;else G=X.get(q.parentId),Z=q.parentId,Y=G??null;if(G!=null)G.childIds.push(W)}if(J)return;for(let W=Q.length-1;W>=1;W--){let q=Q[W];if(q==null)continue;let G=Q[q.parentId];if(G!=null)G.subtreeNodeCount+=q.subtreeNodeCount,G.visibleSubtreeCount+=q.visibleSubtreeCount}}buildDirectoryIndexes(){let J=this.nodes;for(let Q=1;Q<J.length;Q++){let X=J[Q];if(X==null)continue;if(C(X))this.directories.set(Q,L1());let Z=this.directories.get(X.parentId);if(Z!=null){if(Z.childIdByNameId!=null)Z.childIdByNameId.set(X.nameId,Q);S1(Z,Q)}}}computeSubtreeCounts(J){let Q=this.nodes[J];if(Q===void 0)throw Error(`Unknown node ID: ${String(J)}`);if(!C(Q))return Q.subtreeNodeCount=1,Q.visibleSubtreeCount=1,1;let X=this.getDirectoryIndex(J),Z=1;for(let Y of X.childIds)Z+=this.computeSubtreeCounts(Y);return B1(this.nodes,X),Q.subtreeNodeCount=Z,Q.visibleSubtreeCount=Z,Z}};function F6(J,Q="closed",X=null){let Z=OJ(Q);return{activeNodeCount:J.nodes.length-1,collapsedDirectoryIds:new Set,collapseNewDirectoriesByDefault:!1,defaultExpansion:Z,directoriesOpenByDefault:Z==="open",hasCollapsedDirectoryOverrides:!1,directoryLoadInfoById:new Map,expandedDirectoryIds:new Set,instrumentation:X,listeners:new Map,pathCacheByNodeId:new Map([[J.rootId,{path:"",version:0}]]),pathCacheVersion:0,snapshot:J,transactionStack:[]}}function H6(){return{affectedAncestorIds:new Set,affectedNodeIds:new Set,events:[]}}function OJ(J){if(typeof J!=="number")return J;if(!Number.isInteger(J)||J<0)throw Error(`initialExpansion must be "open", "closed", or a non-negative integer depth. Received: ${String(J)}`);return J}function k6(J,Q){if(s(Q,K0))return!0;if(J.defaultExpansion==="open")return!0;if(J.defaultExpansion==="closed")return!1;return E0(Q)<=J.defaultExpansion}function A0(J,Q,X=J.snapshot.nodes[Q]){if(X==null||!C(X))return!1;if(J.directoriesOpenByDefault&&!J.hasCollapsedDirectoryOverrides)return!0;if(J.collapsedDirectoryIds.has(Q))return!1;if(J.expandedDirectoryIds.has(Q))return!0;return k6(J,X)}function W1(J,Q,X,Z=J.snapshot.nodes[Q]){if(Z==null||!C(Z))return;let Y=k6(J,Z);if(X){if(Y){J.collapsedDirectoryIds.delete(Q),J.hasCollapsedDirectoryOverrides=J.collapsedDirectoryIds.size>0;return}J.expandedDirectoryIds.add(Q);return}if(Y){J.collapsedDirectoryIds.add(Q),J.hasCollapsedDirectoryOverrides=!0;return}J.expandedDirectoryIds.delete(Q)}function V6(J,Q){let X=J.directoryLoadInfoById.get(Q);if(X!=null)return X;let Z={activeAttemptId:null,errorMessage:null,nextAttemptId:1,state:"loaded"};return J.directoryLoadInfoById.set(Q,Z),Z}function q1(J,Q){return J.directoryLoadInfoById.get(Q)?.state??"loaded"}function R6(J,Q){let X=V6(J,Q);if(X.state==="loading"&&X.activeAttemptId!=null)return{attemptId:X.activeAttemptId,nodeId:Q,reused:!0};let Z=X.nextAttemptId;return X.activeAttemptId=Z,X.errorMessage=null,X.nextAttemptId+=1,X.state="loading",{attemptId:Z,nodeId:Q,reused:!1}}function E6(J,Q){let X=V6(J,Q);X.activeAttemptId=null,X.errorMessage=null,X.state="unloaded"}function D6(J,Q,X){let Z=J.directoryLoadInfoById.get(Q);if(Z==null||Z.activeAttemptId!==X)return!1;return Z.activeAttemptId=null,Z.errorMessage=null,Z.state="loaded",!0}function T6(J,Q,X){return J.directoryLoadInfoById.get(Q)?.activeAttemptId===X}function C6(J,Q,X,Z){let Y=J.directoryLoadInfoById.get(Q);if(Y==null||Y.activeAttemptId!==X)return!1;return Y.activeAttemptId=null,Y.errorMessage=Z??null,Y.state="error",!0}function b6(J,Q){J.directoryLoadInfoById.delete(Q)}function S6(J,Q,X){let Z=X,Y=J.listeners.get(Q);if(Y!=null)Y.add(Z);else J.listeners.set(Q,new Set([Z]));return()=>{let W=J.listeners.get(Q);if(W==null)return;if(W.delete(Z),W.size===0)J.listeners.delete(Q)}}function f6(J){return{affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],canonicalChanged:!0,operation:"add",path:J.path,projectionChanged:J.projectionChanged,visibleCountDelta:null}}function P6(J){return{affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],canonicalChanged:!0,operation:"remove",path:J.path,projectionChanged:J.projectionChanged,recursive:J.recursive,visibleCountDelta:null}}function x6(J){return{affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],canonicalChanged:!0,from:J.from,operation:"move",projectionChanged:J.projectionChanged,to:J.to,visibleCountDelta:null}}function g6(J){return{affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],canonicalChanged:!1,operation:"expand",path:J.path,projectionChanged:!0,visibleCountDelta:null}}function m6(J){return{affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],canonicalChanged:!1,operation:"collapse",path:J.path,projectionChanged:!0,visibleCountDelta:null}}function I6(J){return{affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],canonicalChanged:!1,operation:"mark-directory-unloaded",path:J.path,projectionChanged:J.projectionChanged,visibleCountDelta:null}}function u6(J){return{affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],attemptId:J.attemptId,canonicalChanged:!1,operation:"begin-child-load",path:J.path,projectionChanged:J.projectionChanged,reused:J.reused,visibleCountDelta:null}}function c6(J){return{affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],attemptId:J.attemptId,canonicalChanged:J.childEvents.some((Q)=>Q.canonicalChanged),childEvents:J.childEvents,operation:"apply-child-patch",path:J.path,projectionChanged:J.projectionChanged,visibleCountDelta:null}}function p6(J){return{affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],attemptId:J.attemptId,canonicalChanged:!1,operation:"complete-child-load",path:J.path,projectionChanged:J.projectionChanged,stale:J.stale,visibleCountDelta:null}}function h6(J){return{affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],attemptId:J.attemptId,canonicalChanged:!1,errorMessage:J.errorMessage,operation:"fail-child-load",path:J.path,projectionChanged:J.projectionChanged,stale:J.stale,visibleCountDelta:null}}function l6(J){return{activeNodeCountAfter:J.activeNodeCountAfter,activeNodeCountBefore:J.activeNodeCountBefore,affectedAncestorIds:J.affectedAncestorIds??[],affectedNodeIds:J.affectedNodeIds??[],cachedPathEntryCountAfter:J.cachedPathEntryCountAfter,cachedPathEntryCountBefore:J.cachedPathEntryCountBefore,canonicalChanged:!1,idsPreserved:J.idsPreserved,loadInfoEntryCountAfter:J.loadInfoEntryCountAfter,loadInfoEntryCountBefore:J.loadInfoEntryCountBefore,mode:J.mode,operation:"cleanup",projectionChanged:J.projectionChanged,reclaimedCachedPathEntryCount:J.reclaimedCachedPathEntryCount,reclaimedLoadInfoEntryCount:J.reclaimedLoadInfoEntryCount,reclaimedNodeSlotCount:J.reclaimedNodeSlotCount,reclaimedSegmentCount:J.reclaimedSegmentCount,segmentCountAfter:J.segmentCountAfter,segmentCountBefore:J.segmentCountBefore,totalNodeSlotCountAfter:J.totalNodeSlotCountAfter,totalNodeSlotCountBefore:J.totalNodeSlotCountBefore,visibleCountDelta:null}}function B0(J,Q,X){return{...X,visibleCountDelta:S4(J)-Q}}function d6(J,Q){let X=S4(J),Z=H6();J.transactionStack.push(Z);try{Q()}catch(Y){throw N6(J,Z,!1),Y}N6(J,Z,!0,S4(J)-X)}function v0(J,Q){let X=J.instrumentation;if(X==null){w6(J,Q);return}T(X,"store.events.record",()=>w6(J,Q))}function w6(J,Q){let X=J.transactionStack[J.transactionStack.length-1]??null;if(X==null){v4(J,Q);return}X.events.push(Q),FJ(X,Q)}function N6(J,Q,X,Z=null){if(J.transactionStack.pop()!==Q)throw Error("Transaction stack underflow");if(!X)return;let Y=J.transactionStack[J.transactionStack.length-1]??null;if(Y!=null){let G=J.instrumentation;if(G==null)y6(Y,Q);else T(G,"store.events.batch.merge",()=>y6(Y,Q));return}let W=LJ(Q,Z),q=J.instrumentation;if(q==null){v4(J,W);return}T(q,"store.events.batch.commit",()=>v4(J,W))}function LJ(J,Q){return{affectedAncestorIds:[...J.affectedAncestorIds],affectedNodeIds:[...J.affectedNodeIds],canonicalChanged:J.events.some((X)=>X.canonicalChanged),events:[...J.events],operation:"batch",projectionChanged:J.events.some((X)=>X.projectionChanged),visibleCountDelta:Q}}function BJ(J,Q){for(let X of Q.affectedAncestorIds)J.affectedAncestorIds.add(X);for(let X of Q.affectedNodeIds)J.affectedNodeIds.add(X)}function y6(J,Q){for(let X of Q.events)J.events.push(X);BJ(J,Q)}function FJ(J,Q){for(let X of Q.affectedNodeIds)J.affectedNodeIds.add(X);for(let X of Q.affectedAncestorIds)J.affectedAncestorIds.add(X)}function v4(J,Q){let X=J.instrumentation;if(X==null){v6(J,Q);return}T(X,"store.events.emit",()=>v6(J,Q))}function v6(J,Q){J.listeners.get(Q.operation)?.forEach((X)=>X(Q)),J.listeners.get("*")?.forEach((X)=>X(Q))}function S4(J){return J.snapshot.nodes[J.snapshot.rootId]?.visibleSubtreeCount??0}function a0(J,Q){if(J.snapshot.options.flattenEmptyDirectories!==!0)return null;let X=J.snapshot.nodes[Q];if(X==null||!C(X)||s(X,K0))return null;let Z=J.snapshot.directories.get(Q);if(Z==null||Z.childIds.length!==1)return null;let Y=Z.childIds[0];if(Y==null)return null;let W=J.snapshot.nodes[Y];if(W==null||!C(W))return null;return Y}function n0(J,Q){let X=Q;while(!0){let Z=a0(J,X);if(Z==null)return X;X=Z}}function x1(J,Q){let X=[Q],Z=Q;while(!0){let Y=a0(J,Z);if(Y==null)return X;X.push(Y),Z=Y}}function o3(J,Q){let X=Q==null?J.snapshot.rootId:F0(J,Q);if(X==null)return[];return kJ(J,X)}function P4(J,Q){let X=V1(Q),Z=X.isDirectory?X.segments:X.segments.slice(0,-1),Y=G1(J,NJ(J,Z)),{createdNodeIds:W,directoryId:q}=VJ(J,Z),G=new Set(W),$=q;if(X.isDirectory){let K=N(J,q);if(s(K,h0))throw Error(`Path already exists: "${Q}"`);f1(K,h0),J.pathCacheByNodeId.set(q,{path:Q,version:J.pathCacheVersion}),G.add(q)}else $=EJ(J,q,X.basename),G.add($);$1(J,q);let A=G1(J,q);return f6({affectedAncestorIds:w0(J,$),affectedNodeIds:[...G],path:Q,projectionChanged:t6(Y,A)})}function x4(J,Q,X){let Z=F0(J,Q);if(Z==null)throw Error(`Path does not exist: "${Q}"`);let Y=N(J,Z);if(s(Y,K0))throw Error("The root node cannot be removed");if(C(Y)&&l(J,Z).childIds.length>0&&X.recursive!==!0)throw Error(`Cannot remove a non-empty directory without recursive: "${Q}"`);let W=Y.parentId,q=G1(J,W),G=n6(J,Z);I4(J,W,Z,Y.nameId),u4(J,W),$1(J,W);let $=G1(J,W);return P6({affectedAncestorIds:w0(J,W),affectedNodeIds:G,path:Q,projectionChanged:t6(q,$),recursive:X.recursive===!0})}function g4(J,Q,X,Z){let Y=F0(J,Q);if(Y==null)throw Error(`Source path does not exist: "${Q}"`);let W=N(J,Y);if(s(W,K0))throw Error("The root node cannot be moved");let q=Z.collision??"error",G=bJ(J,Y,X),$=G1(J,W.parentId),A=G1(J,G.parentId),K=b0(J.snapshot.segmentTable,W.nameId),M=g0(J.snapshot.segmentTable,G.basename);if(G.parentId===W.parentId&&K===G.basename)return null;if(C(W)&&vJ(J,Y,G.parentId))throw Error("Cannot move a directory into one of its descendants");let U=Y1(J.snapshot.nodes,l(J,G.parentId)).get(M),j=G.existingNodeId??U??null;if(j!=null&&j!==Y){if(wJ(J,j,q,M3(W))==="skip")return null}let _=W.parentId;if(I4(J,_,Y,W.nameId),W.parentId=G.parentId,W.nameId=M,J.pathCacheByNodeId.delete(Y),J7(J,Y),m4(J,G.parentId,Y),u4(J,_),J.pathCacheVersion++,$1(J,_),G.parentId!==_)$1(J,G.parentId);let F=G1(J,_),k=G1(J,G.parentId);return x6({affectedAncestorIds:[...new Set([...w0(J,_),...w0(J,G.parentId)])],affectedNodeIds:[Y],from:Q,projectionChanged:e6([$,A],[F,k]),to:u(J,Y)})}function HJ(J,Q){let X=J.pathCacheByNodeId.get(Q);return X!=null&&X.version===J.pathCacheVersion?X.path:null}function i6(J,Q,X){return J.pathCacheByNodeId.set(Q,{path:X,version:J.pathCacheVersion}),X}function u(J,Q){let X=N(J,Q),Z=HJ(J,Q);if(Z!=null)return Z;if(s(X,K0))return i6(J,Q,"");let Y=u(J,X.parentId),W=b0(J.snapshot.segmentTable,X.nameId),q=Y.length===0?W:`${Y}${W}`;return i6(J,Q,C(X)?`${q}/`:q)}function $1(J,Q){let X=J.instrumentation;if(X==null){o6(J,Q);return}T(X,"store.recomputeCountsUpwardFrom",()=>o6(J,Q))}function L3(J,Q){let X=[[Q,0]],{nodes:Z,directories:Y}=J.snapshot;while(X.length>0){let W=X[X.length-1],q=W[0],G=Z[q];if(G==null||!C(G)){f4(J,q,G,!0),X.pop();continue}let $=Y.get(q);if($==null||W[1]>=$.childIds.length){f4(J,q,G,!0),X.pop();continue}let A=$.childIds[W[1]++];X.push([A,0])}}function w0(J,Q){let X=[],Z=Q;while(Z!=null){let Y=N(J,Z);if(X.push(Z),Z===J.snapshot.rootId)break;Z=Y.parentId}return X}function F0(J,Q){if(Q.length===0)return J.snapshot.rootId;let X=l3(Q);return a6(J,X.segments,X.requiresDirectory)}function a6(J,Q,X){let Z=J.snapshot.rootId;for(let W of Q){let q=J.snapshot.segmentTable.idByValue.get(W);if(q===void 0)return null;let G=l(J,Z),$=Y1(J.snapshot.nodes,G).get(q);if($===void 0)return null;Z=$}let Y=N(J,Z);if(X&&!C(Y))return null;return Z}function l(J,Q){let X=J.snapshot.directories.get(Q);if(X===void 0)throw Error(`Unknown directory child index for node ${String(Q)}`);return X}function N(J,Q){let X=J.snapshot.nodes[Q];if(X===void 0||s(X,H1))throw Error(`Unknown node ID: ${String(Q)}`);return X}function kJ(J,Q){let X=J.snapshot.nodes[Q];if(X===void 0||s(X,H1))return[];if(!C(X))return[u(J,Q)];if(l(J,Q).childIds.length===0)return s(X,h0)&&!s(X,K0)?[u(J,Q)]:[];let Z=[],Y=[{childIndex:0,nodeId:Q}];while(Y.length>0){let W=Y[Y.length-1];if(W==null)break;let q=J.snapshot.nodes[W.nodeId];if(q===void 0||s(q,H1)){Y.pop();continue}if(!C(q)){Z.push(u(J,W.nodeId)),Y.pop();continue}let G=l(J,W.nodeId);if(G.childIds.length===0){if(s(q,h0)&&!s(q,K0))Z.push(u(J,W.nodeId));Y.pop();continue}let $=G.childIds[W.childIndex];if($==null){Y.pop();continue}W.childIndex++,Y.push({childIndex:0,nodeId:$})}return Z}function VJ(J,Q){let X=[],Z=J.snapshot.rootId;for(let Y of Q){let W=g0(J.snapshot.segmentTable,Y),q=l(J,Z),G=Y1(J.snapshot.nodes,q).get(W);if(G!==void 0){if(!C(N(J,G)))throw Error(`Cannot create a directory that collides with an existing file: "${Y}"`);Z=G;continue}Z=RJ(J,Z,W),X.push(Z)}return{createdNodeIds:X,directoryId:Z}}function RJ(J,Q,X){let Z=N(J,Q),Y=J.snapshot.nodes.length;if(J.snapshot.nodes.push({depthAndFlags:L0(E0(Z)+1,0,R0),nameId:X,parentId:Q,subtreeNodeCount:1,visibleSubtreeCount:1}),J.snapshot.directories.set(Y,L1()),m4(J,Q,Y),J.collapseNewDirectoriesByDefault)J.collapsedDirectoryIds.add(Y),J.hasCollapsedDirectoryOverrides=!0;return J.activeNodeCount++,Y}function EJ(J,Q,X){let Z=g0(J.snapshot.segmentTable,X),Y=l(J,Q);if(Y1(J.snapshot.nodes,Y).has(Z))throw Error(`Path already exists: "${SJ(J,Q,X)}"`);let W=N(J,Q),q=J.snapshot.nodes.length;return J.snapshot.nodes.push({depthAndFlags:L0(E0(W)+1,0),nameId:Z,parentId:Q,subtreeNodeCount:1,visibleSubtreeCount:1}),m4(J,Q,q),J.activeNodeCount++,q}function DJ(J,Q,X){let Z=0,Y=Q.childIds.length;while(Z<Y){let W=Z+Y>>>1,q=Q.childIds[W];if(q==null){Y=W;continue}if(TJ(J,X,q)<0)Y=W;else Z=W+1}return Z}function m4(J,Q,X){let Z=l(J,Q),Y=N(J,X);Y1(J.snapshot.nodes,Z).set(Y.nameId,X),c3(Z,X,Y.subtreeNodeCount,Y.visibleSubtreeCount);let W=DJ(J,Z,X);Z.childIds.splice(W,0,X),b4(Z,W),F1(J.snapshot.nodes,Z)}function I4(J,Q,X,Z){let Y=l(J,Q),W=v1(Y),q=W.get(X)??-1;Y1(J.snapshot.nodes,Y).delete(Z),W.delete(X);let G=J.snapshot.nodes[X];if(G!=null)c3(Y,X,-G.subtreeNodeCount,-G.visibleSubtreeCount);if(q>=0)Y.childIds.splice(q,1),b4(Y,q),F1(J.snapshot.nodes,Y)}function TJ(J,Q,X){let Z=J.snapshot.options.sort;if(Z==="default")return CJ(J,Q,X);return Z(s6(J,Q),s6(J,X))}function CJ(J,Q,X){let Z=N(J,Q),Y=N(J,X),W=C(Z);if(W!==C(Y))return W?-1:1;let q=j3(O3(J.snapshot.segmentTable,Z.nameId),O3(J.snapshot.segmentTable,Y.nameId));if(q!==0)return q;let G=b0(J.snapshot.segmentTable,Z.nameId),$=b0(J.snapshot.segmentTable,Y.nameId);if(G!==$)return G<$?-1:1;return Q<X?-1:1}function s6(J,Q){let X=N(J,Q),Z=u(J,Q),Y=C(X),W=Y?Z.slice(0,-1):Z;return{basename:b0(J.snapshot.segmentTable,X.nameId),depth:E0(X),isDirectory:Y,path:Z,segments:W.length===0?[]:W.split("/")}}function bJ(J,Q,X){let Z=N(J,Q),Y=F0(J,X);if(Y!=null){let A=N(J,Y);if(C(A))return{basename:b0(J.snapshot.segmentTable,Z.nameId),existingNodeId:null,parentId:Y};let K=l3(X).segments;return{basename:K[K.length-1]??"",existingNodeId:Y,parentId:A.parentId}}let W=l3(X),q=W.segments[W.segments.length-1]??"",G=W.segments.slice(0,-1),$=G.length===0?J.snapshot.rootId:a6(J,G,!0);if($==null)throw Error(`Destination parent does not exist: "${X}"`);return{basename:q,existingNodeId:null,parentId:$}}function wJ(J,Q,X,Z){if(X==="skip")return"skip";if(X==="error")throw Error(`Destination already exists: "${u(J,Q)}"`);let Y=N(J,Q);if(M3(Y)!==Z)throw Error("replace collision requires the same source and destination kinds");if(C(Y)&&l(J,Q).childIds.length>0)throw Error("replace collision does not support non-empty directories");let{parentId:W,nameId:q}=Y;return n6(J,Q),I4(J,W,Q,q),u4(J,W),$1(J,W),"handled"}function n6(J,Q){let X=[],Z=[{nodeId:Q,visitedChildren:!1}];while(Z.length>0){let Y=Z.pop();if(Y==null)break;let W=N(J,Y.nodeId);if(Y.visitedChildren||!C(W)){if(C(W))J.snapshot.directories.delete(Y.nodeId);if(f1(W,H1),J.pathCacheByNodeId.delete(Y.nodeId),J.collapsedDirectoryIds.delete(Y.nodeId))J.hasCollapsedDirectoryOverrides=J.collapsedDirectoryIds.size>0;J.expandedDirectoryIds.delete(Y.nodeId),b6(J,Y.nodeId),J.activeNodeCount--,X.push(Y.nodeId);continue}Z.push({nodeId:Y.nodeId,visitedChildren:!0});let q=l(J,Y.nodeId);for(let G=q.childIds.length-1;G>=0;G--){let $=q.childIds[G];if($!=null)Z.push({nodeId:$,visitedChildren:!1})}}return X}function u4(J,Q){let X=Q;while(X!=null){let Z=N(J,X);if(!C(Z)||s(Z,K0))return;if(l(J,X).childIds.length>0)return;f1(Z,h0),X=Z.parentId===X?null:Z.parentId}}function NJ(J,Q){let X=J.snapshot.rootId;for(let Z of Q){let Y=J.snapshot.segmentTable.idByValue.get(Z);if(Y==null)break;let W=Y1(J.snapshot.nodes,l(J,X)).get(Y);if(W==null)break;if(!C(N(J,W)))break;X=W}return X}function G1(J,Q){let X=yJ(J,Q);if(X==null)return null;let Z=n0(J,X),Y=N(J,Z),W=X===Z?null:x1(J,X).map((q)=>u(J,q));return JSON.stringify({flattenedSegmentPaths:W,hasChildren:l(J,Z).childIds.length>0,path:u(J,Z),terminalKind:M3(Y)})}function t6(J,Q){return e6([J],[Q])}function e6(J,Q){for(let X=0;X<J.length;X+=1){let Z=J[X],Y=Q[X];if(Z==null||Y==null||Z!==Y)return!0}return!1}function yJ(J,Q){let X=Q;while(X!=null){let Z=N(J,X);if(!C(Z)||s(Z,K0))return null;if(!A0(J,X,Z))return X;X=Z.parentId}return null}function J7(J,Q){let X=N(J,Q);if(Q6(X,(Q===J.snapshot.rootId?-1:E0(N(J,X.parentId)))+1),!C(X))return;let Z=l(J,Q);for(let Y of Z.childIds)J7(J,Y)}function vJ(J,Q,X){let Z=X;while(Z!=null){if(Z===Q)return!0;let Y=N(J,Z);if(Z===J.snapshot.rootId)return!1;Z=Y.parentId}return!1}function f4(J,Q,X=N(J,Q),Z=!1){let Y=J.instrumentation;if(Y==null){r6(J,Q,X,Z);return}T(Y,"store.recomputeNodeCounts",()=>r6(J,Q,X,Z))}function o6(J,Q){let X=Q;while(X!=null){let Z=N(J,X),Y=Z.subtreeNodeCount,W=Z.visibleSubtreeCount;if(f4(J,X,Z),X===J.snapshot.rootId)return;let q=Z.subtreeNodeCount-Y,G=Z.visibleSubtreeCount-W,$=Z.parentId;if(q!==0||G!==0)c3(l(J,$),X,q,G);X=$}}function r6(J,Q,X,Z){if(!C(X)){X.subtreeNodeCount=1,X.visibleSubtreeCount=1;return}let Y=l(J,Q);if(Z){let G=J.instrumentation;if(G==null)B1(J.snapshot.nodes,Y);else T(G,"store.recomputeNodeCounts.rebuildChildAggregates",()=>B1(J.snapshot.nodes,Y))}let W=1+Y.totalChildSubtreeNodeCount,q=Y.totalChildVisibleSubtreeCount;if(X.subtreeNodeCount=W,s(X,K0)){X.visibleSubtreeCount=q;return}X.visibleSubtreeCount=a0(J,Q)!=null?q:A0(J,Q,X)?1+q:1}function SJ(J,Q,X){let Z=u(J,Q);return Z.length===0?X:`${Z}${X}`}function g1(J){return J!=null&&!s(J,H1)}function r3(J,Q){let X=J.snapshot.nodes[Q];if(!g1(X)||!C(X)||s(X,K0))return null;return X}function fJ(J){let Q=0;for(let[X,Z]of J.pathCacheByNodeId){if(Z.version!==J.pathCacheVersion)continue;if(!g1(J.snapshot.nodes[X]))continue;Q+=1}return Q}function PJ(J){return Math.max(0,J.valueById.length-1)}function Q7(J){return{activeNodeCount:J.activeNodeCount,cachedPathEntryCount:fJ(J),loadInfoEntryCount:J.directoryLoadInfoById.size,segmentCount:PJ(J.snapshot.segmentTable),totalNodeSlotCount:Math.max(0,J.snapshot.nodes.length-1)}}function xJ(J,Q,X,Z){return{activeNodeCountAfter:Z.activeNodeCount,activeNodeCountBefore:X.activeNodeCount,cachedPathEntryCountAfter:Z.cachedPathEntryCount,cachedPathEntryCountBefore:X.cachedPathEntryCount,idsPreserved:Q,loadInfoEntryCountAfter:Z.loadInfoEntryCount,loadInfoEntryCountBefore:X.loadInfoEntryCount,mode:J,reclaimedCachedPathEntryCount:X.cachedPathEntryCount-Z.cachedPathEntryCount,reclaimedLoadInfoEntryCount:X.loadInfoEntryCount-Z.loadInfoEntryCount,reclaimedNodeSlotCount:X.totalNodeSlotCount-Z.totalNodeSlotCount,reclaimedSegmentCount:X.segmentCount-Z.segmentCount,segmentCountAfter:Z.segmentCount,segmentCountBefore:X.segmentCount,totalNodeSlotCountAfter:Z.totalNodeSlotCount,totalNodeSlotCountBefore:X.totalNodeSlotCount}}function X7(J){let Q=[],X=[];for(let Z of J.collapsedDirectoryIds)if(r3(J,Z)!=null)Q.push(u(J,Z));for(let Z of J.expandedDirectoryIds)if(r3(J,Z)!=null)X.push(u(J,Z));return{collapsedPaths:Q,expandedPaths:X}}function Z7(J){let Q=[];for(let[X,Z]of J.directoryLoadInfoById){if(r3(J,X)==null||q1(J,X)==="loaded")continue;Q.push({info:{activeAttemptId:null,errorMessage:Z.errorMessage,nextAttemptId:Z.nextAttemptId,state:Z.state},path:u(J,X)})}return Q}function Y7(J,Q){J.collapsedDirectoryIds.clear(),J.hasCollapsedDirectoryOverrides=!1,J.expandedDirectoryIds.clear();for(let X of Q.expandedPaths){let Z=F0(J,X);if(Z==null)continue;W1(J,Z,!0,N(J,Z))}for(let X of Q.collapsedPaths){let Z=F0(J,X);if(Z==null)continue;W1(J,Z,!1,N(J,Z))}}function W7(J,Q){J.directoryLoadInfoById.clear();for(let X of Q){let Z=F0(J,X.path);if(Z==null)continue;if(r3(J,Z)==null)continue;J.directoryLoadInfoById.set(Z,{activeAttemptId:null,errorMessage:X.info.errorMessage,nextAttemptId:X.info.nextAttemptId,state:X.info.state})}}function gJ(J){J.pathCacheVersion+=1,J.pathCacheByNodeId.clear(),J.pathCacheByNodeId.set(J.snapshot.rootId,{path:"",version:J.pathCacheVersion})}function mJ(J){let Q=J.snapshot.segmentTable,X=d3();for(let Z of J.snapshot.nodes){if(!g1(Z))continue;if(s(Z,K0)){Z.nameId=0;continue}Z.nameId=g0(X,b0(Q,Z.nameId))}J.snapshot.segmentTable=X}function IJ(J){for(let[Q,X]of J.snapshot.directories){let Z=J.snapshot.nodes[Q];if(!g1(Z)||!C(Z)){J.snapshot.directories.delete(Q);continue}let Y=X.childIds.filter((W)=>{let q=J.snapshot.nodes[W];return g1(q)&&q.parentId===Q});X.childIds=Y,X.childIdByNameId=new Map(Y.map((W)=>[N(J,W).nameId,W])),X.childPositionById=new Map(Y.map((W,q)=>[W,q])),B1(J.snapshot.nodes,X)}}function uJ(J){let Q=J.snapshot.nodes.length-1;while(Q>J.snapshot.rootId){let X=J.snapshot.nodes[Q];if(g1(X))break;Q-=1}J.snapshot.nodes.length=Q+1}function cJ(J){let Q=X7(J),X=Z7(J);T(J.instrumentation,"store.cleanup.stable.clearPathCaches",()=>gJ(J)),T(J.instrumentation,"store.cleanup.stable.rebuildSegmentTable",()=>mJ(J)),T(J.instrumentation,"store.cleanup.stable.rebuildDirectoryIndexes",()=>IJ(J)),T(J.instrumentation,"store.cleanup.stable.trimTrailingRemovedNodeSlots",()=>uJ(J)),T(J.instrumentation,"store.cleanup.stable.restoreExpansionOverrides",()=>Y7(J,Q)),T(J.instrumentation,"store.cleanup.stable.restoreDirectoryLoadInfos",()=>W7(J,X)),T(J.instrumentation,"store.cleanup.stable.recomputeCounts",()=>L3(J,J.snapshot.rootId))}function pJ(J){let Q=X7(J),X=Z7(J),Z=T(J.instrumentation,"store.cleanup.aggressive.listPaths",()=>o3(J)),Y=Z6({...J.snapshot.options},J.instrumentation),W=T(J.instrumentation,"store.cleanup.aggressive.rebuildSnapshot",()=>{let q=new s3(Y);return q.appendPaths(Z),q.finish()});J.snapshot=W,J.activeNodeCount=W.nodes.length-1,J.pathCacheByNodeId=new Map([[W.rootId,{path:"",version:0}]]),J.pathCacheVersion=0,T(J.instrumentation,"store.cleanup.aggressive.restoreExpansionOverrides",()=>Y7(J,Q)),T(J.instrumentation,"store.cleanup.aggressive.restoreDirectoryLoadInfos",()=>W7(J,X)),T(J.instrumentation,"store.cleanup.aggressive.recomputeCounts",()=>L3(J,J.snapshot.rootId))}function q7(J){for(let Q of J.directoryLoadInfoById.values())if(Q.state==="loading"&&Q.activeAttemptId!=null)return!0;return!1}function G7(J,Q){let X=Q7(J);if(Q==="stable")T(J.instrumentation,"store.cleanup.stable",()=>cJ(J));else T(J.instrumentation,"store.cleanup.aggressive",()=>pJ(J));let Z=Q7(J);return xJ(Q,Q==="stable",X,Z)}var hJ=64;function lJ(J,Q){let X=Q+2;if(X<=J.length)return J;let Z=J.length;while(Z<X)Z*=2;let Y=new Int32Array(Z);return Y.fill(-1),Y.set(J),Y}function M0(J){return N(J,J.snapshot.rootId).visibleSubtreeCount}function K7(J,Q,X,Z){let Y=N(J,Q.terminalNodeId),W=Math.max(1,Y.visibleSubtreeCount);return Math.min(Z-1,X+W-1)}function dJ(J,Q,X,Z){return{ancestorPaths:Z,index:Q.index,posInSet:Q.posInSet,row:B3(J,Q.cursor),setSize:Q.setSize,subtreeEndIndex:K7(J,Q.cursor,Q.index,X)}}function A7(J,Q,X,Z,Y,W){let q=l(J,Q),{childIndex:G,childVisibleIndex:$,localVisibleIndex:A}=p3(J.snapshot.nodes,q,X),K=q.childIds[G];if(K==null)throw Error(`Visible index ${String(X)} is out of range`);return iJ(J,K,A,Z+$,Y+1,G,q.childIds.length,W)}function iJ(J,Q,X,Z,Y,W,q,G){if(!C(N(J,Q))){if(X===0)return{ancestors:G,cursor:{headNodeId:Q,terminalNodeId:Q,visibleDepth:Y},index:Z,posInSet:W,setSize:q};throw Error(`Visible index ${String(X)} is out of range for file`)}let $=H7(J,Q,Y);if(X===0)return{ancestors:G,cursor:$,index:Z,posInSet:W,setSize:q};let A=N(J,$.terminalNodeId);if(!C(A)||!A0(J,$.terminalNodeId,A))throw Error(`Visible index ${String(X)} is out of range for collapsed directory`);return A7(J,$.terminalNodeId,X-1,Z+1,$.visibleDepth,[...G,{cursor:$,index:Z,posInSet:W,setSize:q}])}function M7(J,Q){let X=M0(J);if(Q<0||Q>=X)return null;let Z=A7(J,J.snapshot.rootId,Q,0,-1,[]),Y=Z.ancestors.map((q)=>u(J,q.cursor.terminalNodeId)),W=null;return{ancestorPaths:Y,get ancestorRows(){if(W!=null)return W;let q=[],G=[];for(let $ of Z.ancestors){let A=dJ(J,$,X,[...G]);q.push(A),G.push(A.row.path)}return W=q,W},index:Z.index,posInSet:Z.posInSet,row:B3(J,Z.cursor),setSize:Z.setSize,subtreeEndIndex:K7(J,Z.cursor,Z.index,X)}}function _7(J,Q,X){let Z=J.instrumentation,Y=M0(J);if(Y<=0||X<Q)return[];let W=Math.max(0,Math.min(Q,Y-1)),q=Math.max(W,Math.min(X,Y-1));if(Z==null){if(W===0)return rJ(J,q+1);let M=[],U=$7(J,W);for(let j=W;j<=q&&U!=null;j++){let _=B3(J,U);M.push(_),U=U7(J,U)}return M}let G=[],$=0,A=0,K=T(Z,"store.getVisibleSlice.selectFirstRow",()=>$7(J,W));for(let M=W;M<=q&&K!=null;M++){let U=T(Z,"store.getVisibleSlice.materializeRow",()=>B3(J,K));if(G.push(U),U.isFlattened)$++,A+=U.flattenedSegments?.length??0;K=T(Z,"store.getVisibleSlice.advanceCursor",()=>U7(J,K))}return P1(Z,"workload.visibleRowsRead",G.length),P1(Z,"workload.flattenedRowsRead",$),P1(Z,"workload.flattenedSegmentsRead",A),G}function p4(J,Q=M0(J)){let X=J.instrumentation;if(X==null)return z7(J,Q);return T(X,"store.getVisibleTreeProjection",()=>z7(J,Q))}function j7(J){return oJ(p4(J))}function O7(J,Q){let X=F0(J,Q);if(X==null||X===J.snapshot.rootId)return null;if(C(N(J,X))&&n0(J,X)!==X)return null;let Z=0,Y=X,{nodes:W,rootId:q}=J.snapshot;while(Y!==q){let G=N(J,Y).parentId,$=l(J,G),A=v1($).get(Y);if(A==null)throw Error(`Child ${String(Y)} was not found in its parent index`);if(Z+=t5(W,$,A),G!==q){let K=N(J,G),M=a0(J,G);if(!A0(J,G,K)&&M!==Y)return null;if(n0(J,G)===G)Z+=1}Y=G}return Z}function L7(J,Q){let X=F0(J,Q);if(X==null)throw Error(`Path does not exist: "${Q}"`);let Z=N(J,X);if(!C(Z))throw Error(`Path is not a directory: "${Q}"`);if(A0(J,X,Z))return null;return W1(J,X,!0,Z),$1(J,X),g6({affectedAncestorIds:w0(J,X),affectedNodeIds:[X],path:Q,projectionChanged:!0})}function B7(J,Q){let X=F0(J,Q);if(X==null)throw Error(`Path does not exist: "${Q}"`);let Z=N(J,X);if(!C(Z))throw Error(`Path is not a directory: "${Q}"`);if(!A0(J,X,Z))return null;return W1(J,X,!1,Z),$1(J,X),m6({affectedAncestorIds:w0(J,X),affectedNodeIds:[X],path:Q,projectionChanged:!0})}function $7(J,Q){if(Q<0||Q>=M0(J))return null;return F7(J,J.snapshot.rootId,Q,-1)}function F7(J,Q,X,Z){let Y=l(J,Q),W=J.instrumentation,{childIndex:q,localVisibleIndex:G}=W==null?p3(J.snapshot.nodes,Y,X):T(W,"store.getVisibleSlice.selectChildIndex",()=>p3(J.snapshot.nodes,Y,X)),$=Y.childIds[q];if($!=null)return c4(J,$,G,Z+1);throw Error(`Visible index ${String(X)} is out of range`)}function c4(J,Q,X,Z){if(!C(N(J,Q))){if(X===0)return{headNodeId:Q,terminalNodeId:Q,visibleDepth:Z};throw Error(`Visible index ${String(X)} is out of range for file`)}let Y=H7(J,Q,Z);if(X===0)return Y;let W=N(J,Y.terminalNodeId);if(!C(W)||!A0(J,Y.terminalNodeId,W))throw Error(`Visible index ${String(X)} is out of range for collapsed directory`);return F7(J,Y.terminalNodeId,X-1,Y.visibleDepth)}function H7(J,Q,X){if(!C(N(J,Q)))return{headNodeId:Q,terminalNodeId:Q,visibleDepth:X};if(J.instrumentation==null)return{headNodeId:Q,terminalNodeId:n0(J,Q),visibleDepth:X};return{headNodeId:Q,terminalNodeId:T(J.instrumentation,"store.getVisibleSlice.flatten.resolveTerminalDirectory",()=>n0(J,Q)),visibleDepth:X}}function sJ(J,Q){let X=N(J,Q);if(!C(X))return!0;let Z=X.parentId;if(Z===J.snapshot.rootId)return!0;return a0(J,Z)!==Q}function U7(J,Q){let X=N(J,Q.terminalNodeId);if(C(X)){let W=l(J,Q.terminalNodeId);if(A0(J,Q.terminalNodeId,X)&&W.childIds.length>0){let q=W.childIds[0];return q==null?null:c4(J,q,0,Q.visibleDepth+1)}}let{terminalNodeId:Z,visibleDepth:Y}=Q;while(!0){let W=N(J,Z);if(Z===J.snapshot.rootId)return null;let q=W.parentId,G=l(J,q),$=v1(G).get(Z)??-1;if($<0)throw Error(`Child ${String(Z)} was not found in its parent index`);let A=G.childIds[$+1]??null;if(A!=null)return c4(J,A,0,Y);if(sJ(J,Z))Y--;Z=q}}function oJ(J){let Q=J.paths.length,X=Array(Q);for(let Z=0;Z<Q;Z+=1){let Y=J.getParentIndex(Z);X[Z]={index:Z,parentPath:Y>=0?J.paths[Y]??null:null,path:J.paths[Z]??"",posInSet:J.posInSetByIndex[Z]??0,setSize:J.setSizeByIndex[Z]??0}}return{getParentIndex:J.getParentIndex,rows:X,get visibleIndexByPath(){return J.visibleIndexByPath}}}function z7(J,Q){let X=Array(Q),Z=new Int32Array(Q),Y=new Int32Array(Q),W=new Int32Array(Q),q=new Int32Array(hJ);q.fill(-1);let G=0,{nodes:$,directories:A,segmentTable:K}=J.snapshot,M=[[A.get(J.snapshot.rootId),0,-1,""]],U=J.snapshot.options.flattenEmptyDirectories,j=J.pathCacheByNodeId,_=J.pathCacheVersion,F=K.valueById;while(M.length>0&&G<Q){let B=M[M.length-1],H=B[0];if(B[1]>=H.childIds.length){M.pop();continue}let w=B[1],P=H.childIds[B[1]++],U0=$[P],o=B[2]+1,_0=B[3];q=lJ(q,o);let a,e=P;if(!C(U0)){let J0=j.get(P);a=J0!=null&&J0.version===_?J0.path:`${_0}${F[U0.nameId]}`}else e=U?n0(J,P):P,a=e===P?`${_0}${F[U0.nameId]}/`:u(J,e);Z[G]=q[o],X[G]=a,Y[G]=w,W[G]=H.childIds.length,q[o+1]=G,G+=1;let $0=$[e];if($0!=null&&C($0)&&A0(J,e,$0))M.push([A.get(e),0,o,a])}if(G<Q)X.length=G;let k=Z.subarray(0,G),b=Y.subarray(0,G),E=W.subarray(0,G),L=null;return{getParentIndex(B){return B<0||B>=G?-1:k[B]??-1},paths:X,posInSetByIndex:b,setSizeByIndex:E,get visibleIndexByPath(){if(L==null){L=new Map;for(let B=0;B<G;B+=1)L.set(X[B]??"",B)}return L}}}function rJ(J,Q){let X=Array(Q),Z=0,{nodes:Y,directories:W,segmentTable:q}=J.snapshot,G=[[W.get(J.snapshot.rootId),0,-1]],$=q.valueById,A=J.snapshot.options.flattenEmptyDirectories,K=J.pathCacheByNodeId,M=J.pathCacheVersion;while(G.length>0&&Z<Q){let U=G[G.length-1],j=U[0];if(U[1]>=j.childIds.length){G.pop();continue}let _=j.childIds[U[1]++],F=Y[_],k=U[2]+1;if(!C(F)){let B=K.get(_);X[Z++]={depth:k,flattenedSegments:void 0,hasChildren:!1,id:_,isExpanded:!1,isFlattened:!1,isLoading:!1,kind:"file",loadState:void 0,name:$[F.nameId],path:B!=null&&B.version===M?B.path:u(J,_)};continue}let b=A?n0(J,_):_,E={headNodeId:_,terminalNodeId:b,visibleDepth:k};X[Z++]=B3(J,E);let L=Y[b];if(L!=null&&C(L)&&A0(J,b,L))G.push([W.get(b),0,k])}if(Z<Q)X.length=Z;return X}function B3(J,Q){let X=N(J,Q.terminalNodeId),Z=C(X)?aJ(J,Q):null,Y=u(J,Q.terminalNodeId),W=b0(J.snapshot.segmentTable,X.nameId),q=C(X)&&l(J,Q.terminalNodeId).childIds.length>0,G=Q.headNodeId!==Q.terminalNodeId,$=J.instrumentation,A=G?$==null?x1(J,Q.headNodeId).map((K)=>{let M=N(J,K);return{isTerminal:K===Q.terminalNodeId,name:b0(J.snapshot.segmentTable,M.nameId),nodeId:K,path:u(J,K)}}):T($,"store.getVisibleSlice.flatten.collectSegments",()=>x1(J,Q.headNodeId).map((K)=>{let M=N(J,K);return{isTerminal:K===Q.terminalNodeId,name:b0(J.snapshot.segmentTable,M.nameId),nodeId:K,path:u(J,K)}})):void 0;return{depth:Q.visibleDepth,flattenedSegments:A,hasChildren:q,id:Q.terminalNodeId,isExpanded:C(X)&&A0(J,Q.terminalNodeId,X),isFlattened:G,isLoading:Z==="loading",kind:C(X)?"directory":"file",loadState:Z==null||Z==="loaded"?void 0:Z,name:W,path:Y}}function aJ(J,Q){if(Q.headNodeId===Q.terminalNodeId)return q1(J,Q.terminalNodeId);let X=x1(J,Q.headNodeId),Z=!1,Y=!1;for(let W of X){let q=q1(J,W);if(q==="loading")return"loading";if(q==="error"){Y=!0;continue}if(q==="unloaded")Z=!0}if(Y)return"error";if(Z)return"unloaded";return"loaded"}function nJ(J){let{directories:Q,nodes:X,options:Z,rootId:Y,presortedDirectoryNodeIds:W}=J.snapshot,q=Z.flattenEmptyDirectories===!0,G=(j)=>{let _=X[j];if(_==null||!C(_))return;let F=Q.get(j);if(F==null)throw Error(`Unknown directory child index for node ${String(j)}`);let k=F.childIds,b=k.length,E=0,L=0;for(let H=0;H<b;H++){let w=k[H];if(w==null)continue;let P=X[w];E+=P.subtreeNodeCount,L+=P.visibleSubtreeCount}if(F.totalChildSubtreeNodeCount=E,F.totalChildVisibleSubtreeCount=L,b>=n5)F1(X,F);_.subtreeNodeCount=1+E;let B;if(q&&b===1){let H=X[k[0]];B=H!=null&&C(H)?L:1+L}else B=1+L;_.visibleSubtreeCount=B};if(W!=null)for(let j=W.length-1;j>=0;j--)G(W[j]);else for(let j=X.length-1;j>=1;j--)G(j);let $=X[Y],A=Q.get(Y);if($==null||A==null)return;let K=A.childIds,M=0,U=0;for(let j=0;j<K.length;j++){let _=K[j];if(_==null)continue;let F=X[_];M+=F.subtreeNodeCount,U+=F.visibleSubtreeCount}A.totalChildSubtreeNodeCount=M,A.totalChildVisibleSubtreeCount=U,F1(X,A),$.subtreeNodeCount=1+M,$.visibleSubtreeCount=U}function tJ(J){return J.initialExpansion==="open"&&(J.initialExpandedPaths==null||J.initialExpandedPaths.length===0)}var m1=class J{#J;constructor(Q={}){let X=_3(Q),Z=T(X,"store.builder.create",()=>new s3(Q));if(Q.preparedInput!=null){let G=L6(Q.preparedInput);if(G!=null)Z.appendPresortedPaths(G,B6(Q.preparedInput));else Z.appendPreparedPaths(O6(Q.preparedInput),!1)}else{let G=Q.paths??[];if(Q.presorted===!0)Z.appendPaths(G);else Z.appendPreparedPaths(T(X,"store.preparePathEntries",()=>i3(G,Q)))}let Y=T(X,"store.builder.finish",()=>Z.finish({skipSubtreeCountPass:!0})),W=T(X,"store.state.detectAllDirectoriesExpanded",()=>(Q.initialExpansion??"closed")==="closed"&&Z.didMatchAllInitialExpandedPaths());if(this.#J=T(X,"store.state.create",()=>F6(Y,W?"open":Q.initialExpansion??"closed",X)),W)this.#J.collapseNewDirectoriesByDefault=!0;let q=W?this.#J.snapshot.directories.size-1:T(X,"store.state.initializeExpandedPaths",()=>this.initializeExpandedPaths(Q.initialExpandedPaths));if(W||tJ(Q)||(Q.initialExpansion??"closed")==="closed"&&q===this.#J.snapshot.directories.size-1||(Q.initialExpandedPaths?.length??0)>0&&T(X,"store.state.checkAllDirectoriesExpanded",()=>this.hasAllDirectoriesExpanded()))T(X,"store.state.initializeOpenVisibleCounts",()=>nJ(this.#J));else T(X,"store.state.recomputeCounts",()=>L3(this.#J,this.#J.snapshot.rootId))}static preparePaths(Q,X={}){return M6(Q,X)}static prepareInput(Q,X={}){return _6(Q,X)}static preparePresortedInput(Q){return j6(Q)}list(Q){return T(this.#J.instrumentation,"store.list",()=>o3(this.#J,Q))}add(Q){T(this.#J.instrumentation,"store.add",()=>{let X=M0(this.#J);v0(this.#J,B0(this.#J,X,P4(this.#J,Q)))})}remove(Q,X={}){T(this.#J.instrumentation,"store.remove",()=>{let Z=M0(this.#J);v0(this.#J,B0(this.#J,Z,x4(this.#J,Q,X)))})}move(Q,X,Z={}){T(this.#J.instrumentation,"store.move",()=>{let Y=M0(this.#J),W=g4(this.#J,Q,X,Z);if(W!=null)v0(this.#J,B0(this.#J,Y,W))})}batch(Q){d6(this.#J,()=>{if(typeof Q==="function"){Q(this);return}for(let X of Q)switch(X.type){case"add":this.add(X.path);break;case"remove":this.remove(X.path,{recursive:X.recursive});break;case"move":this.move(X.from,X.to,{collision:X.collision});break}})}getVisibleCount(){return T(this.#J.instrumentation,"store.getVisibleCount",()=>M0(this.#J))}getVisibleSlice(Q,X){return T(this.#J.instrumentation,"store.getVisibleSlice",()=>_7(this.#J,Q,X))}getVisibleRowContext(Q){return T(this.#J.instrumentation,"store.getVisibleRowContext",()=>M7(this.#J,Q))}getVisibleTreeProjection(){return j7(this.#J)}getVisibleTreeProjectionData(Q){return p4(this.#J,Q)}getVisibleIndex(Q){return T(this.#J.instrumentation,"store.getVisibleIndex",()=>O7(this.#J,Q))}getPathInfo(Q){return T(this.#J.instrumentation,"store.getPathInfo",()=>{let X=F0(this.#J,Q);if(X==null)return null;let Z=N(this.#J,X);return{depth:E0(Z),kind:C(Z)?"directory":"file",path:u(this.#J,X)}})}isExpanded(Q){return T(this.#J.instrumentation,"store.isExpanded",()=>{let X=this.requireDirectoryNodeId(Q),Z=N(this.#J,X);return A0(this.#J,X,Z)})}expand(Q){T(this.#J.instrumentation,"store.expand",()=>{let X=M0(this.#J),Z=L7(this.#J,Q);if(Z!=null)v0(this.#J,B0(this.#J,X,Z))})}collapse(Q){T(this.#J.instrumentation,"store.collapse",()=>{let X=M0(this.#J),Z=B7(this.#J,Q);if(Z!=null)v0(this.#J,B0(this.#J,X,Z))})}on(Q,X){return S6(this.#J,Q,X)}getDirectoryLoadState(Q){let X=this.requireDirectoryNodeId(Q);return q1(this.#J,X)}markDirectoryUnloaded(Q){T(this.#J.instrumentation,"store.markDirectoryUnloaded",()=>{let X=this.requireDirectoryNodeId(Q);if(l(this.#J,X).childIds.length>0)throw Error(`Cannot mark a directory with known children as unloaded: "${Q}"`);let Z=M0(this.#J);E6(this.#J,X),v0(this.#J,B0(this.#J,Z,I6({affectedAncestorIds:w0(this.#J,X),affectedNodeIds:[X],path:Q,projectionChanged:this.isDirectoryProjectionVisible(X)})))})}beginChildLoad(Q){return T(this.#J.instrumentation,"store.beginChildLoad",()=>{let X=this.requireDirectoryNodeId(Q),Z=M0(this.#J),Y=R6(this.#J,X);return v0(this.#J,B0(this.#J,Z,u6({affectedAncestorIds:w0(this.#J,X),affectedNodeIds:[X],attemptId:Y.attemptId,path:Q,projectionChanged:this.isDirectoryProjectionVisible(X),reused:Y.reused}))),Y})}applyChildPatch(Q,X){return T(this.#J.instrumentation,"store.applyChildPatch",()=>{let Z=this.resolveActiveDirectoryNodeId(Q.nodeId);if(Z==null||q1(this.#J,Z)!=="loading"||!T6(this.#J,Z,Q.attemptId))return!1;let Y=u(this.#J,Z);this.validateChildPatch(Y,X);let W=M0(this.#J),q=[];for(let $ of X.operations){eJ(Y,$);let A=M0(this.#J);switch($.type){case"add":q.push(B0(this.#J,A,P4(this.#J,$.path)));break;case"remove":q.push(B0(this.#J,A,x4(this.#J,$.path,{recursive:$.recursive})));break;case"move":{let K=g4(this.#J,$.from,$.to,{collision:$.collision});if(K!=null)q.push(B0(this.#J,A,K));break}}}let G=q.some(($)=>$.projectionChanged)||this.isDirectoryProjectionVisible(Z);return v0(this.#J,B0(this.#J,W,c6({affectedAncestorIds:w0(this.#J,Z),affectedNodeIds:[Z],attemptId:Q.attemptId,childEvents:q,path:u(this.#J,Z),projectionChanged:G}))),!0})}completeChildLoad(Q){return T(this.#J.instrumentation,"store.completeChildLoad",()=>{let X=this.resolveActiveDirectoryNodeId(Q.nodeId);if(X==null)return!1;let Z=M0(this.#J),Y=D6(this.#J,X,Q.attemptId);return v0(this.#J,B0(this.#J,Z,p6({affectedAncestorIds:w0(this.#J,X),affectedNodeIds:[X],attemptId:Q.attemptId,path:u(this.#J,X),projectionChanged:this.isDirectoryProjectionVisible(X),stale:!Y}))),Y})}failChildLoad(Q,X){return T(this.#J.instrumentation,"store.failChildLoad",()=>{let Z=this.resolveActiveDirectoryNodeId(Q.nodeId);if(Z==null)return!1;let Y=M0(this.#J),W=C6(this.#J,Z,Q.attemptId,X);return v0(this.#J,B0(this.#J,Y,h6({affectedAncestorIds:w0(this.#J,Z),affectedNodeIds:[Z],attemptId:Q.attemptId,errorMessage:X,path:u(this.#J,Z),projectionChanged:this.isDirectoryProjectionVisible(Z),stale:!W}))),W})}cleanup(Q={}){return T(this.#J.instrumentation,"store.cleanup",()=>{if(this.#J.transactionStack.length>0)throw Error("Cleanup cannot run during an open batch or transaction.");if(q7(this.#J))throw Error("Cleanup cannot run while directory loads are active.");let X=M0(this.#J),Z=G7(this.#J,Q.mode??"stable");return v0(this.#J,B0(this.#J,X,l6({...Z,affectedAncestorIds:[],affectedNodeIds:[],projectionChanged:Z.idsPreserved===!1}))),Z})}getNodeCount(){return this.#J.activeNodeCount}initializeExpandedPaths(Q){if(Q==null||Q.length===0)return 0;let X=0,Z=[],Y=[],W=0,q=null,G=this.#J.snapshot.segmentTable,$=G.valueById,A=this.#J.snapshot.nodes,K=new Map;for(let M of Q){if(q!=null&&M<q)q=null,W=0,Z.length=0,Y.length=0;let U=M.length>0&&M.charCodeAt(M.length-1)===47?M.length-1:M.length;if(U===0){q=M,W=U,Z.length=0,Y.length=0;continue}let j=0,_=0;if(q!=null){let L=Math.min(U,W),B=!0;for(let H=0;H<L;H+=1){let w=M.charCodeAt(H);if(w!==q.charCodeAt(H)){B=!1;break}if(w===47)j+=1,_=H+1}if(B){if(L===W&&U>L&&M.charCodeAt(L)===47)j+=1,_=L+1;else if(L===U&&W>L&&q.charCodeAt(L)===47)j+=1,_=U+1}j=Math.min(j,Y.length)}let F=j===0?this.#J.snapshot.rootId:Y[j-1]??this.#J.snapshot.rootId,k=j,b=!0,E=_;while(E<=U){let L=M.indexOf("/",E),B=L===-1||L>U?U:L,H=M.slice(E,B),w=l(this.#J,F).childIds,P=k===j?Z[k]??0:0,U0=P,o,_0=K.get(H)??k1(H);K.set(H,_0);let a=(e,$0)=>{for(U0=e;U0<$0;U0+=1){let J0=w[U0],S0=A[J0],d=$[S0.nameId];if(d===H)return o=J0,!0;let Y0=j3(O3(G,S0.nameId),_0);if(Y0>0||Y0===0&&d>H)return!1}return!1};if(!a(P,w.length)&&P>0)a(0,P);if(o===void 0){b=!1;break}if(!C(N(this.#J,o))){b=!1;break}if(Z[k]=U0,Y[k]=o,F=o,k+=1,B===U)break;E=B+1}if(q=M,W=U,Z.length=k,Y.length=k,!b){q=null,W=0,Z.length=0,Y.length=0;continue}for(let L=j;L<k;L+=1){let B=Y[L];if(B==null)continue;let H=N(this.#J,B);if(A0(this.#J,B,H))continue;W1(this.#J,B,!0,H),X+=1}}return X}hasAllDirectoriesExpanded(){for(let Q of this.#J.snapshot.directories.keys()){if(Q===this.#J.snapshot.rootId)continue;let X=N(this.#J,Q);if(!A0(this.#J,Q,X))return!1}return!0}requireDirectoryNodeId(Q){let X=F0(this.#J,Q);if(X==null)throw Error(`Path does not exist: "${Q}"`);if(!C(N(this.#J,X)))throw Error(`Path is not a directory: "${Q}"`);return X}resolveActiveDirectoryNodeId(Q){try{if(!C(N(this.#J,Q)))throw Error(`Node is not a directory: ${String(Q)}`);return Q}catch{return null}}isDirectoryProjectionVisible(Q){let X=Q;while(X!==this.#J.snapshot.rootId){let Z=N(this.#J,X).parentId;if(Z!==this.#J.snapshot.rootId){let Y=N(this.#J,Z),W=a0(this.#J,Z);if(!A0(this.#J,Z,Y)&&W!==X)return!1}X=Z}return!0}validateChildPatch(Q,X){new J({paths:this.list(Q),presorted:!0,sort:this.#J.snapshot.options.sort}).batch(X.operations)}};function eJ(J,Q){switch(Q.type){case"add":case"remove":if(!Q.path.startsWith(J)||Q.path===J)throw Error(`Child patch operation must stay within ${J}: "${Q.path}"`);break;case"move":if(!Q.from.startsWith(J)||!Q.to.startsWith(J)||Q.from===J||Q.to===J)throw Error(`Child patch move must stay within ${J}: "${Q.from}" -> "${Q.to}"`);break}}function k7(J){return m1.preparePresortedInput(J)}var JQ=[`<symbol id="file-tree-builtin-bash" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8 1C2.24 1 1 2.24 1 8s1.24 7 7 7 7-1.24 7-7-1.24-7-7-7" class="bg" opacity=".2"/>
  <path fill="currentColor" d="M11.5 11a.5.5 0 0 1 0 1h-3a.5.5 0 0 1 0-1zM7 6.75C7 6.42 6.64 6 6 6s-1 .42-1 .75q-.01.25.22.41.26.21.89.35.74.14 1.28.53c.37.29.61.7.61 1.21 0 .87-.68 1.5-1.5 1.7v.55a.5.5 0 0 1-1 0v-.56c-.82-.18-1.5-.82-1.5-1.69a.5.5 0 0 1 1 0c0 .33.36.75 1 .75s1-.42 1-.75q.01-.25-.22-.41a2 2 0 0 0-.89-.35q-.74-.14-1.28-.53A1.5 1.5 0 0 1 4 6.75c0-.87.68-1.5 1.5-1.7V4.5a.5.5 0 0 1 1 0v.56c.82.18 1.5.82 1.5 1.69a.5.5 0 0 1-1 0" class="fg-stroke"/>
</symbol>`,`<symbol id="file-tree-builtin-c" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M8 1q.084 0 .166.021.098.023.186.075c1.055.624 4.22 2.486 5.277 3.11.085.05.15.112.209.192h-.002l.028.037a.5.5 0 0 1 .103.21q.031.102.033.21v6.29a.71.71 0 0 1-.347.616l-5.307 3.144a.68.68 0 0 1-.693 0l-5.307-3.144A.72.72 0 0 1 2 11.145V4.832a.71.71 0 0 1 .346-.612l5.288-3.126A.7.7 0 0 1 7.992 1zm2.901 4.349a3.75 3.75 0 1 0 0 5.302l-1.06-1.06a2.25 2.25 0 1 1 0-3.182z" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-cpp" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M8 1q.084 0 .166.021.098.023.186.075c1.055.624 4.22 2.486 5.277 3.11.085.05.15.112.209.192h-.002l.028.037a.5.5 0 0 1 .103.21q.031.102.033.21v6.29a.71.71 0 0 1-.347.616l-5.307 3.144a.68.68 0 0 1-.693 0l-5.307-3.144A.72.72 0 0 1 2 11.145V4.832a.71.71 0 0 1 .346-.612l5.288-3.126A.7.7 0 0 1 7.992 1zm2.901 4.349a3.75 3.75 0 1 0 0 5.302l-1.06-1.06a2.25 2.25 0 1 1 0-3.182z" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-css" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8 15c-5.76 0-7-1.24-7-7V2a1 1 0 0 1 1-1h6c5.77 0 7 1.24 7 7s-1.24 7-7 7" class="vector" opacity=".2"/>
  <path fill="currentColor" d="M10.1 9.19h.73c.03.49.22.6 1 .6.76 0 .93-.12.93-.68 0-.52-.17-.67-.94-.85-1.38-.3-1.68-.56-1.68-1.47 0-1.05.3-1.29 1.67-1.29 1.29 0 1.57.2 1.6 1.13h-.74c-.01-.34-.17-.42-.85-.42-.77 0-.94.1-.94.58 0 .42.17.55.96.73 1.36.3 1.66.58 1.66 1.59 0 1.14-.31 1.39-1.73 1.39-1.39 0-1.69-.24-1.67-1.31m-3.9 0h.74c.03.49.21.6.99.6.76 0 .93-.12.93-.68 0-.52-.17-.67-.93-.85-1.39-.3-1.69-.56-1.69-1.47 0-1.05.3-1.29 1.67-1.29 1.3 0 1.58.2 1.6 1.13h-.73c-.02-.34-.18-.42-.85-.42-.78 0-.95.1-.95.58 0 .42.17.55.96.73 1.37.3 1.67.58 1.67 1.59 0 1.14-.32 1.39-1.74 1.39-1.38 0-1.68-.24-1.66-1.31m-1.22 0h.75c-.09 1.07-.37 1.31-1.56 1.31-1.37 0-1.68-.45-1.68-2.5 0-1.96.36-2.5 1.68-2.5 1.16 0 1.44.25 1.52 1.35h-.76c-.08-.52-.22-.64-.76-.64-.74 0-.9.33-.9 1.78 0 1.47.16 1.8.9 1.8.58 0 .74-.11.8-.6"/>
</symbol>`,`<symbol id="file-tree-builtin-database" viewBox="0 0 16 16">
  <path fill="currentColor" d="M14.953 9.733a12.4 12.4 0 0 1-.244 1.936c-.207.933-.532 1.58-.996 2.044s-1.11.789-2.044.996C10.73 14.918 9.533 15 8 15s-2.73-.082-3.669-.291c-.933-.207-1.58-.532-2.044-.996s-.789-1.11-.996-2.044c-.122-.547-.2-1.182-.244-1.92q.23.364.532.667c.64.639 1.482 1.031 2.533 1.265 1.046.232 2.33.315 3.884.315 1.555 0 2.838-.083 3.884-.315 1.051-.234 1.893-.626 2.532-1.265a4 4 0 0 0 .541-.683"/>
  <path fill="currentColor" d="M14.93 5.924c-.046.663-.118 1.24-.23 1.743-.207.932-.532 1.579-.995 2.042s-1.11.789-2.042.996c-.938.209-2.135.291-3.667.291-1.531 0-2.729-.082-3.667-.29-.932-.208-1.579-.534-2.042-.997s-.789-1.11-.996-2.042a12 12 0 0 1-.227-1.683l.016-.188a4 4 0 0 0 .5.62c.638.639 1.48 1.031 2.532 1.265 1.046.232 2.33.315 3.884.315 1.555 0 2.838-.083 3.884-.315 1.051-.234 1.893-.626 2.532-1.265.192-.192.357-.404.506-.633z"/>
  <path fill="currentColor" d="M8 1c1.533 0 2.73.082 3.669.291.933.207 1.58.533 2.044.996.403.404.904.944.91 1.695.004.764-.509 1.318-.918 1.727-.463.463-1.11.789-2.042.996-.938.209-2.135.291-3.667.291-1.531 0-2.729-.082-3.667-.29-.932-.208-1.579-.534-2.042-.997-.406-.406-.915-.953-.915-1.71 0-.758.509-1.305.915-1.712.464-.463 1.11-.789 2.044-.996C5.27 1.082 6.467 1 8 1"/>
</symbol>`,`<symbol id="file-tree-builtin-default" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8 1v3a3 3 0 0 0 3 3h3v5.5a2.5 2.5 0 0 1-2.5 2.5h-7A2.5 2.5 0 0 1 2 12.5v-9A2.5 2.5 0 0 1 4.5 1z" class="bg" opacity=".4"/>
  <path fill="currentColor" d="M9.5 1a.5.5 0 0 1 .354.146l4 4A.5.5 0 0 1 14 5.5V6h-3a2 2 0 0 1-2-2V1z" class="fg"/>
</symbol>`,`<symbol id="file-tree-builtin-font" viewBox="0 0 16 16">
  <path fill="currentColor" d="M12.3 13c-1.59 0-2.68-.99-2.68-2.5 0-1.43 1-2.34 2.88-2.35h2.16v-.83c0-1.08-.62-1.68-1.73-1.68-1.05 0-1.66.54-1.73 1.36H9.93c.09-1.43 1.06-2.48 3.05-2.48 1.75 0 3.02.95 3.02 2.68v5.66h-1.29v-1.02h-.04c-.41.66-1.16 1.16-2.37 1.16m.36-1.12c1.14 0 2-.72 2-1.74v-.96H12.6c-1.12 0-1.6.54-1.6 1.28 0 .97.8 1.42 1.66 1.42m-11.24.98H0L3.8 2h1.39l3.8 10.86H7.54l-1.08-3.2H2.5zm3.09-9.25h-.04l-1.6 4.95H6.1z"/>
</symbol>`,`<symbol id="file-tree-builtin-git" viewBox="0 0 16 16">
  <path fill="currentColor" d="M14.74 7.38 8.62 1.26a.9.9 0 0 0-1.27 0L6.08 2.53l1.61 1.61a1.07 1.07 0 0 1 1.36 1.37l1.55 1.55a1.07 1.07 0 0 1 1.1 1.77 1.07 1.07 0 0 1-1.74-1.16L8.5 6.22v3.8a1.07 1.07 0 1 1-.89-.02V6.15a1.07 1.07 0 0 1-.58-1.4l-1.58-1.6-4.2 4.2a.9.9 0 0 0 0 1.27l6.12 6.12a.9.9 0 0 0 1.27 0l6.09-6.09a.9.9 0 0 0 0-1.27"/>
</symbol>`,`<symbol id="file-tree-builtin-go" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M4.41 4.57A3.2 3.2 0 0 1 6.87 5q.74.49 1.08 1.29.08.12-.1.16l-1.55.4c-.14.03-.15.04-.27-.1a1 1 0 0 0-.44-.34 1.6 1.6 0 0 0-1.68.14q-.95.61-.94 1.73c0 .73.52 1.33 1.25 1.43q.95.1 1.58-.6l.25-.34h-1.8c-.19 0-.24-.12-.17-.27.12-.28.34-.76.47-1a.3.3 0 0 1 .24-.14h2.98a4 4 0 0 1 .64-1.19 4 4 0 0 1 2.6-1.52 3.5 3.5 0 0 1 2.64.46q1.13.73 1.31 2.04a3.5 3.5 0 0 1-1.06 3.09q-.93.92-2.23 1.17l-.74.08a3.5 3.5 0 0 1-2.27-.8 3 3 0 0 1-.93-1.42 4 4 0 0 1-.39.61 4 4 0 0 1-2.64 1.56 3.3 3.3 0 0 1-2.5-.6 3 3 0 0 1-1.18-2.03 3.5 3.5 0 0 1 .8-2.67 4 4 0 0 1 2.6-1.58M13.1 7.5a1.53 1.53 0 0 0-1.9-1.21q-1.3.3-1.62 1.59a1.5 1.5 0 0 0 .85 1.72q.77.33 1.52-.05a2 2 0 0 0 1.18-1.74q0-.17-.03-.3" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-html" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8 1C2.24 1 1 2.24 1 8s1.24 7 7 7 7-1.24 7-7-1.24-7-7-7" class="bg" opacity=".2"/>
  <path fill="currentColor" d="M10.48 3.76a.5.5 0 0 1 .4.58L10.6 5.8h1.14a.5.5 0 0 1 0 1h-1.32L10 9.2h1.08a.5.5 0 0 1 0 1H9.8l-.3 1.64a.5.5 0 1 1-.98-.18l.27-1.46H6.4l-.3 1.64a.5.5 0 1 1-.98-.18l.27-1.46H4.25a.5.5 0 0 1 0-1h1.32L6 6.8H4.93a.5.5 0 0 1 0-1H6.2l.3-1.64a.5.5 0 1 1 .98.18L7.2 5.8h2.4l.3-1.64a.5.5 0 0 1 .58-.4M6.58 9.2h2.4l.44-2.4h-2.4z" class="fg"/>
</symbol>`,`<symbol id="file-tree-builtin-image" viewBox="0 0 16 16">
  <path fill="currentColor" d="M12.5 2A2.5 2.5 0 0 1 15 4.5v4.67l-4.05-3.54-4.08 4.08-3-2L1 10.6V4.5A2.5 2.5 0 0 1 3.5 2z" opacity=".3"/>
  <path fill="currentColor" d="M15 10.5v1a2.5 2.5 0 0 1-2.5 2.5h-9a2.5 2.5 0 0 1-2.46-2.04L4 9l3 2 4-4zm-7-5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0"/>
</symbol>`,`<symbol id="file-tree-builtin-javascript" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8 1C2.24 1 1 2.24 1 8s1.24 7 7 7 7-1.24 7-7-1.24-7-7-7" class="bg" opacity=".2"/>
  <path fill="currentColor" d="M8.1 9.64h.95c.04.62.28.76 1.28.76s1.2-.14 1.2-.85c0-.66-.2-.85-1.2-1.07-1.79-.38-2.18-.7-2.18-1.86C8.15 5.3 8.54 5 10.31 5c1.67 0 2.04.26 2.07 1.42h-.95c-.02-.43-.23-.53-1.1-.53-1 0-1.22.14-1.22.74 0 .52.22.7 1.24.92 1.76.38 2.15.73 2.15 2 0 1.44-.4 1.75-2.24 1.75-1.8 0-2.18-.3-2.15-1.66M3.5 9.5h.98c0 .76.15.92.85.92.77 0 .94-.18.94-1.02V5.1h1v4.34c0 1.54-.35 1.87-1.92 1.87-1.55 0-1.89-.32-1.86-1.8"/>
</symbol>`,`<symbol id="file-tree-builtin-json" viewBox="0 0 16 16">
  <path fill="currentColor" d="M13.25 11.5V9.75a.5.5 0 0 1 .36-.48l.55-.15a1.16 1.16 0 0 0 0-2.24l-.55-.15a.5.5 0 0 1-.36-.48V4.5a2.5 2.5 0 0 0-2.5-2.5h-.25a.5.5 0 0 0 0 1h.25a1.5 1.5 0 0 1 1.5 1.5v1.75a1.5 1.5 0 0 0 1.09 1.44l.54.15a.16.16 0 0 1 0 .32l-.54.15a1.5 1.5 0 0 0-1.09 1.44v1.75a1.5 1.5 0 0 1-1.5 1.5h-.25a.5.5 0 0 0 0 1h.25a2.5 2.5 0 0 0 2.5-2.5m-10.5 0V9.75a.5.5 0 0 0-.36-.48l-.55-.15a1.16 1.16 0 0 1 0-2.24l.55-.15a.5.5 0 0 0 .36-.48V4.5A2.5 2.5 0 0 1 5.25 2h.25a.5.5 0 0 1 0 1h-.25a1.5 1.5 0 0 0-1.5 1.5v1.75a1.5 1.5 0 0 1-1.09 1.44l-.54.15a.16.16 0 0 0 0 .32l.54.15a1.5 1.5 0 0 1 1.09 1.45v1.74a1.5 1.5 0 0 0 1.5 1.5h.25a.5.5 0 0 1 0 1h-.25a2.5 2.5 0 0 1-2.5-2.5"/>
</symbol>`,`<symbol id="file-tree-builtin-markdown" viewBox="0 0 16 16">
  <path fill="currentColor" d="M1 12V4h2l2 2.5L7 4h2v8H7V7.5l-2 2-2-2V12zm9-3 3 3.5L16 9h-2V4h-2v5z"/>
</symbol>`,`<symbol id="file-tree-builtin-mcp" viewBox="0 0 16 16">
  <path fill="currentColor" d="M9.26-.04a3 3 0 0 1 2 .82 2.8 2.8 0 0 1 .8 2.35 2.9 2.9 0 0 1 2.41.8l.03.02a2.74 2.74 0 0 1 0 3.94l-5.8 5.69-.04.06-.02.07q0 .04.02.07.01.04.04.06l1.2 1.17a.55.55 0 0 1 0 .79.6.6 0 0 1-.81 0l-1.2-1.17a1.3 1.3 0 0 1 0-1.84L13.7 7.1a1.65 1.65 0 0 0 .37-1.82 2 2 0 0 0-.37-.54l-.03-.03a1.73 1.73 0 0 0-2.4 0L6.47 9.4l-.07.06a.58.58 0 0 1-.92-.18.6.6 0 0 1 .12-.6l4.85-4.76a1.65 1.65 0 0 0 0-2.36 1.73 1.73 0 0 0-2.4 0l-6.43 6.3a.6.6 0 0 1-.8 0 .55.55 0 0 1 0-.8L7.25.79a3 3 0 0 1 2-.82"/>
  <path fill="currentColor" d="M9.26 2.19a.6.6 0 0 1 .52.34.6.6 0 0 1 0 .43l-.12.18L4.9 7.79a1.65 1.65 0 0 0 0 2.36 1.73 1.73 0 0 0 2.4 0l4.75-4.66a.58.58 0 0 1 .93.18.6.6 0 0 1-.12.61l-4.75 4.66a2.9 2.9 0 0 1-4.01 0 2.75 2.75 0 0 1-.62-3.04A3 3 0 0 1 4.1 7l4.74-4.65a.6.6 0 0 1 .4-.16"/>
</symbol>`,`<symbol id="file-tree-builtin-python" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8.33 8.4H10c1.16 0 1.9-.73 1.9-1.86V5.08q0-.24.25-.24h.74c.75 0 1.33.32 1.66.97q.4.73.41 1.46c.09.9.09 1.78-.24 2.67-.25.73-.75 1.3-1.58 1.46h-4.8c-.08 0-.25 0-.25.08v.4s.17.09.25.09h2.82q.34-.02.33.32v1.06c0 .56-.25.97-.75 1.13-.41.16-.83.33-1.24.4a7 7 0 0 1-2.98-.07 3 3 0 0 1-1.16-.49c-.33-.32-.58-.65-.5-1.14v-2.91c0-1.13.67-1.78 1.82-1.78q.89-.1 1.66-.08m2.32 4.86a.65.65 0 0 0-.66-.65c-.34 0-.67.33-.67.65s.33.57.67.65a.65.65 0 0 0 .66-.65" class="bg" opacity=".8"/>
  <path fill="currentColor" d="M7.67 7.6H6c-1.16 0-1.9.73-1.9 1.86v1.46q0 .24-.25.24h-.74c-.75 0-1.33-.32-1.66-.97a3 3 0 0 1-.41-1.46 6 6 0 0 1 .24-2.67c.25-.73.75-1.3 1.58-1.46h4.8c.08 0 .25 0 .25-.08v-.4s-.17-.09-.25-.09H4.85c-.24 0-.33-.08-.33-.32V2.65c0-.56.25-.97.75-1.13.41-.16.83-.33 1.24-.4a7 7 0 0 1 2.98.07c.41.09.83.25 1.16.49.33.32.58.65.5 1.13v2.92c0 1.14-.67 1.78-1.82 1.78-.58.08-1.16.08-1.66.08M5.35 2.73c0 .33.25.65.66.65.33 0 .66-.32.66-.65 0-.32-.33-.56-.66-.64a.65.65 0 0 0-.66.64" class="fg"/>
</symbol>`,`<symbol id="file-tree-builtin-ruby" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M11.04 2c.48 0 .92.23 1.18.6l2.54 3.65c.37.52.3 1.23-.15 1.69l-5.58 5.64a1.47 1.47 0 0 1-2.06 0L1.39 7.94a1.3 1.3 0 0 1-.15-1.7l2.54-3.63q.2-.3.5-.45.33-.16.68-.16zm.84 2.17a.5.5 0 0 0-.7-.05L8 6.84 4.83 4.12a.5.5 0 0 0-.65.76L6.65 7H3.5a.5.5 0 0 0 0 1h9a.5.5 0 0 0 0-1H9.35l2.48-2.12a.5.5 0 0 0 .05-.7" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-rust" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M8 .8a.2.2 0 0 1 .18.1l.38.6.16.02.5-.53.01-.01a.2.2 0 0 1 .33.08l.25.68.16.05.59-.43h.02a.2.2 0 0 1 .3.14l.12.71.15.08.65-.3a.2.2 0 0 1 .2.02.2.2 0 0 1 .1.18l-.03.72.12.1.71-.16a.2.2 0 0 1 .25.25l-.17.7q.06.06.1.13l.73-.03A.2.2 0 0 1 14 4a.2.2 0 0 1 .02.2l-.3.66.08.14.71.12a.2.2 0 0 1 .14.32l-.43.59.05.16.68.25a.2.2 0 0 1 .07.35l-.53.49.01.16.62.38a.2.2 0 0 1 0 .36l-.62.38-.01.16.53.5a.2.2 0 0 1-.07.34l-.68.25-.05.16.43.59a.2.2 0 0 1-.14.32l-.72.12-.07.15.3.65a.2.2 0 0 1-.02.2.2.2 0 0 1-.18.1l-.72-.03-.1.13.16.7a.2.2 0 0 1-.25.25l-.7-.17-.13.1.03.73a.2.2 0 0 1-.1.18.2.2 0 0 1-.2.02l-.66-.3-.14.08-.12.71a.2.2 0 0 1-.32.14l-.59-.43-.16.05-.25.68a.2.2 0 0 1-.34.07l-.5-.53-.16.01-.38.62a.2.2 0 0 1-.36 0l-.38-.62-.16-.01-.5.53a.2.2 0 0 1-.34-.07l-.25-.68-.16-.05-.59.43a.2.2 0 0 1-.32-.14L5 13.78l-.15-.07-.65.3a.2.2 0 0 1-.2-.02.2.2 0 0 1-.1-.18l.03-.72-.13-.1-.7.16a.2.2 0 0 1-.25-.25l.17-.7-.1-.13-.73.03a.2.2 0 0 1-.2-.3l.3-.66-.08-.14-.71-.12a.2.2 0 0 1-.14-.32l.43-.59-.05-.16-.68-.25A.2.2 0 0 1 1 9.22l.53-.5-.02-.16-.6-.38A.2.2 0 0 1 .8 8a.2.2 0 0 1 .1-.18l.6-.38.02-.16-.53-.5a.2.2 0 0 1 .07-.34l.68-.25.05-.16-.43-.59a.2.2 0 0 1 .14-.32L2.2 5l.08-.15L2 4.2a.2.2 0 0 1 .2-.3l.72.03.1-.13-.16-.7a.2.2 0 0 1 .25-.25l.7.16.13-.1-.03-.72A.2.2 0 0 1 4 2a.2.2 0 0 1 .2-.02l.65.3L5 2.2l.12-.71v-.03a.2.2 0 0 1 .32-.1l.59.41.16-.04.25-.68.01-.02A.2.2 0 0 1 6.8.99l.49.53.16-.02.38-.61.02-.02A.2.2 0 0 1 8 .79M6.8 9.45h1.26l.06.01q.03.01.03.05v1.52q0 .07-.09.06h-4.5A5.4 5.4 0 0 0 8 13.42a5.4 5.4 0 0 0 4.45-2.33h-2.42c-.36 0-.68-.5-.77-.75-.08-.22-.2-.91-.25-1.12-.15-.61-.59-.71-.78-.73H6.8zM8 2.58a5.4 5.4 0 0 0-4.07 1.85h5.74l.17.02c.23.03.6.12.96.35.34.23.83.68.83 1.4 0 .66-.55 1.16-1.08 1.5.42.33.7.53.86 1.44.04.17.34.32.62.29.29-.03.62-.16.62-.75v-.24q0-.1.07-.1h.68A5.43 5.43 0 0 0 8 2.59M2.96 6.03a5.4 5.4 0 0 0-.19 3.37h1.66V6.03zM6.8 7.06h1.66c.35 0 .77-.12.77-.47 0-.42-.55-.53-.65-.53H6.8z" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-swift" viewBox="0 0 16 16">
  <path fill="currentColor" d="M9.63 1c6.15 4.35 4.16 9.15 4.16 9.15s1.75 2.05 1.04 3.85c0 0-.72-1.26-1.93-1.26-1.17 0-1.85 1.26-4.2 1.26C3.47 14 1 9.46 1 9.46c4.71 3.22 7.93.94 7.93.94C6.8 9.12 2.29 3 2.29 3c3.93 3.47 5.63 4.39 5.63 4.39-1.01-.87-3.86-5.13-3.86-5.13C6.34 4.66 10.86 8 10.86 8c1.28-3.7-1.23-7-1.23-7"/>
</symbol>`,`<symbol id="file-tree-builtin-table" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8 4a3 3 0 0 0 3 3h3v5.5a2.5 2.5 0 0 1-2.5 2.5h-7A2.5 2.5 0 0 1 2 12.5v-9A2.5 2.5 0 0 1 4.5 1H8z" class="bg" opacity=".4"/>
  <path fill="currentColor" d="M11.5 8a.5.5 0 0 1 .5.5v4a.5.5 0 0 1-.5.5h-7a.5.5 0 0 1-.5-.5v-4a.5.5 0 0 1 .5-.5zM5 12h2.5v-1H5zm3.5 0H11v-1H8.5zM5 10h2.5V9H5zm3.5 0H11V9H8.5zm1-9a.5.5 0 0 1 .354.146l4 4A.5.5 0 0 1 14 5.5V6h-3a2 2 0 0 1-2-2V1z" class="fg"/>
</symbol>`,`<symbol id="file-tree-builtin-text" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M8 4a3 3 0 0 0 3 3h3v5.5a2.5 2.5 0 0 1-2.5 2.5h-7A2.5 2.5 0 0 1 2 12.5v-9A2.5 2.5 0 0 1 4.5 1H8z" class="bg" clip-rule="evenodd" opacity=".4"/>
  <path fill="currentColor" d="M8.5 11a.5.5 0 0 1 0 1h-3a.5.5 0 0 1 0-1zm2-2a.5.5 0 0 1 0 1h-5a.5.5 0 0 1 0-1zm-1-8a.5.5 0 0 1 .354.146l4 4A.5.5 0 0 1 14 5.5V6h-3a2 2 0 0 1-2-2V1z"/>
</symbol>`,`<symbol id="file-tree-builtin-typescript" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8 1C2.24 1 1 2.24 1 8s1.24 7 7 7 7-1.24 7-7-1.24-7-7-7" class="bg" opacity=".2"/>
  <path fill="currentColor" d="M8.1 9.64h.95c.04.62.28.76 1.28.76s1.2-.14 1.2-.85c0-.66-.2-.85-1.2-1.07-1.79-.38-2.18-.7-2.18-1.86C8.15 5.3 8.54 5 10.31 5c1.67 0 2.04.26 2.07 1.42h-.95c-.02-.43-.23-.53-1.1-.53-1 0-1.22.14-1.22.74 0 .52.22.7 1.24.92 1.76.38 2.15.73 2.15 2 0 1.44-.4 1.75-2.24 1.75-1.8 0-2.18-.3-2.15-1.66m-3 1.57V5.99H3.5v-.9h4.21v.9H6.1v5.22z"/>
</symbol>`,`<symbol id="file-tree-builtin-zip" viewBox="0 0 16 16">
  <path fill="currentColor" d="M4.585 2a2 2 0 0 1 1.028.285l1.788 1.072a1 1 0 0 0 .514.143H12A2 2 0 0 1 13.935 5H0V4a2 2 0 0 1 2-2z" class="bg" opacity=".5"/>
  <path fill="currentColor" fill-rule="evenodd" d="M14 12a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2v-1.25h1v-1H0V6h14zM9.9 8.25c-.883 0-1.9.5-1.9.5H7v1h1v1s1.017.5 1.9.5c.884 0 1.6-.672 1.6-1.5s-.716-1.5-1.6-1.5M2 9.75v1h1v-1zm2 0v1h1v-1zm2 0v1h1v-1zm-5-1v1h1v-1zm2 0v1h1v-1zm2 0v1h1v-1z" class="fg" clip-rule="evenodd"/>
</symbol>`],QQ=[`<symbol id="file-tree-builtin-astro" viewBox="0 0 16 16">
  <path fill="currentColor" d="M6.08 13.92c-.63-.57-.81-1.79-.55-2.67.45.56 1.08.73 1.73.83 1 .15 1.99.1 2.92-.37l.32-.19q.13.38.08.78a2.1 2.1 0 0 1-.9 1.5q-.3.24-.61.43c-.64.44-.81.95-.57 1.69l.02.08a1.7 1.7 0 0 1-.74-.64 2 2 0 0 1-.3-.98q0-.27-.02-.52-.07-.61-.61-.62a.7.7 0 0 0-.75.6z" class="bg" opacity=".6"/>
  <path fill="currentColor" d="M2.5 11.1s1.86-.9 3.72-.9l1.4-4.39c.05-.21.2-.36.38-.36s.33.15.38.36l1.4 4.38c2.2 0 3.72.92 3.72.92l-3.16-8.69q-.13-.4-.45-.42H6.11q-.3.02-.45.42z" class="fg"/>
</symbol>`,`<symbol id="file-tree-builtin-babel" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M9.49.5q1.92.05 2.66.54 1.27.6 1.35 1.52v.23a4 4 0 0 1-.53 1.9l-1.38 1.24q-.74.38-.72.63c.77.82 1.33 1.29.85 2.42q-.47 1.1-2.04 2.28c-.5.32-1.88 1.35-2.96 1.86-1.64.77-3.1 1.4-4.65 1.89-.51.16-1.5.16-1.5.16L.5 15A76 76 0 0 0 5.76 3.49q-.1-.08-.1-.2.1 0 .32-.35l-.03-.09q-1.17.39-2.38 1.3l-.13.03q0-.1-.21-.16-.46.31-.82.7l-.13-.19.16-.06-.03-.16-.34.29L2 4.5q.36-.48.72-.54l.04-.1V3.8q.16 0 .15-.06l.13-.06a6 6 0 0 0 1.13-.9v-.03H4.1l-.12.07q0-.1-.1-.1l-.15.07-.04-.1q.93-.52 1.63-1.05Q7.89.65 9.5.5M8.46 7.83l-.32.04c-1.31.54-2.31.82-2.91.88a71 71 0 0 0-2.2 4.54h.07q.58-.04 3.04-1.42.13 0 1.66-1.05L9.18 9.7v.03q.45-.2.81-1.3v-.2q-.5-.46-1.53-.4m.28-5.75c-.5.1-.75.19-.72.38l-1.16 2.6q-.17.1-.34.95-.3.48-.25.77v.1l.22.05A15 15 0 0 1 8.86 6c1.1-.71 2.12-1.38 2.8-2.54q.24-.33.21-.54-.02-.33-.4-.54c-.54 0-1.07-.34-1.63-.28l-.94-.03z" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-biome" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8 2 4.88 7.35a7 7 0 0 1 3.7-.13l1.04.25-.99 4.16-1.05-.25a2.7 2.7 0 0 0-3.07 1.45l-.98-.47a4 4 0 0 1 1.07-1.31 3.8 3.8 0 0 1 3.23-.71l.5-2.08a6 6 0 0 0-5.07 1.12A5.9 5.9 0 0 0 1 14h14z"/>
</symbol>`,`<symbol id="file-tree-builtin-bootstrap" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M11.72 1.5A2.5 2.5 0 0 1 14.2 4q.02 1.08.3 2.09c.22.73.56 1.24 1.08 1.45.22.08.4.27.4.5s-.18.43-.4.51q-.76.34-1.08 1.45c-.2.65-.27 1.32-.3 2a2.5 2.5 0 0 1-2.48 2.5H4.25A2.6 2.6 0 0 1 1.7 12c-.04-.85-.1-1.68-.22-2.04C1.26 9.23.92 8.7.4 8.5.18 8.42 0 8.23 0 8s.18-.42.4-.5q.77-.35 1.09-1.46c.1-.36.17-1.19.2-2.04a2.6 2.6 0 0 1 2.56-2.5z" class="bg" clip-rule="evenodd" opacity=".2"/>
  <path fill="currentColor" fill-rule="evenodd" d="M8.47 4.54c1.23 0 2.04.68 2.04 1.73 0 .73-.55 1.39-1.24 1.5v.04c.94.1 1.58.77 1.58 1.7 0 1.2-.9 1.95-2.37 1.95H5.97a.3.3 0 0 1-.2-.08.3.3 0 0 1-.08-.2V4.82a.3.3 0 0 1 .08-.2.3.3 0 0 1 .2-.08zm-1.7 6.04h1.49q1.47-.01 1.49-1.15Q9.74 8.31 8.2 8.3H6.77zm0-5.16v2.06h1.21c.93 0 1.45-.38 1.45-1.06 0-.65-.44-1-1.22-1z" class="fg" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-browserslist" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8.88 6.96c0 3.82 3.72 4.7 5.7 3.74-.23.9-1.04 1.67-2.35 1.93-.02.4.42 1.28.82 1.63-.9.35-1.94-.12-2.51-.48a5 5 0 0 0-.32 1.87c-.68 0-1.57-1-1.8-1.37-.3.18-.85 1.15-.96 1.72a2.4 2.4 0 0 1-.81-.86 2.4 2.4 0 0 1-.3-1.15c-.38.27-1.48.95-1.99 1.18-.25-.58-.15-1.3 0-2.06-.21.12-1.8.27-2.43.12.32-.36.75-1.19.94-1.57A4.5 4.5 0 0 1 .44 10.6c.48-.22.97-.53 1.49-1.06C1.26 9.17.24 8.64 0 7.7a6 6 0 0 0 1.79-.32C1.28 7.08.44 6.15.6 5.01c.42.21 1.3.37 1.73.3a3.4 3.4 0 0 1-.25-2.75 5 5 0 0 0 1.48 1c-.08-.8.3-2.31.8-2.71.2.46.73 1.21 1.08 1.4.09-.61.87-2.06 1.57-2.25 0 .5.27 1.4.5 1.67.51-.54 2.25-1.44 3.64-1.13-.43.45-.75.61-.86.98 1.05 0 2.78.34 4.27 1.93-2.34-.89-5.69.56-5.69 3.5" class="bg" opacity=".5"/>
  <path fill="currentColor" d="M11.21 3.59a4.1 4.1 0 0 0 2.47 2.89c.24-.22.61-.38.95-.19.76.44.2 1.26-.34 1.66l-.07.06a13 13 0 0 1-4.49 1.61l-.3-.43a10.5 10.5 0 0 0 4.13-1.31 1 1 0 0 0 .23-.25.5.5 0 0 0-.21-.69l-.15-.06a4.5 4.5 0 0 1-1.77-1.31 4.5 4.5 0 0 1-.88-1.77q.2-.12.43-.21"/>
  <path fill="currentColor" d="M10.36 5.18a.4.4 0 0 0-.03.38c.09.2.3.3.46.23s.24-.3.15-.5l-.01-.02q.23.13.34.39a.83.83 0 0 1-.43 1.08.8.8 0 0 1-1.08-.43.83.83 0 0 1 .6-1.13"/>
</symbol>`,`<symbol id="file-tree-builtin-bun" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8 14c3.87 0 7-2.46 7-5.49 0-1.88-1.2-3.53-3.04-4.52q-1.1-.61-1.84-1.07C9.2 2.35 8.64 2 8 2s-1.36.45-2.31 1.03A29 29 0 0 1 4.04 4C2.2 4.98 1 6.63 1 8.51 1 11.54 4.13 14 8 14M7.18 3.88q.3-.66.3-1.37c0-.08.11-.1.13-.01.38 1.57-.53 2.35-1.2 2.61-.08.03-.12-.07-.06-.12a3 3 0 0 0 .83-1.12m1.2-.05a3 3 0 0 0-.45-1.3V2.5c-.04-.07.05-.15.1-.1 1.15 1.2.77 2.3.33 2.87-.05.05-.13 0-.11-.08q.21-.67.13-1.37m1.04-.32a3 3 0 0 0-.94-1.02v-.01c-.06-.05-.01-.16.07-.12 1.51.61 1.61 1.8 1.43 2.5l-.03.03a.07.07 0 0 1-.1-.06 3 3 0 0 0-.43-1.32m-2.97.32c-.36.3-.74.43-1.2.56q-.11 0-.1-.1a3.5 3.5 0 0 0 1.76-1.57s.09-.07.1.04c0 .18-.2.76-.56 1.07m2.89 6.36q-.13.52-.55.88a1.3 1.3 0 0 1-.75.35 1.3 1.3 0 0 1-.77-.35 1.7 1.7 0 0 1-.54-.88.13.13 0 0 1 .15-.15h2.31a.14.14 0 0 1 .15.15M6.15 8.95a1.1 1.1 0 0 1-1.39-.14A1.1 1.1 0 0 1 5.12 7a1.1 1.1 0 0 1 1.2.25 1.1 1.1 0 0 1-.17 1.69m4.96 0a1.1 1.1 0 0 1-1.4-.14 1.1 1.1 0 0 1 .37-1.8 1.1 1.1 0 0 1 1.2.25 1.1 1.1 0 0 1 .24 1.2 1 1 0 0 1-.41.5"/>
</symbol>`,`<symbol id="file-tree-builtin-claude" viewBox="0 0 16 16">
  <path fill="currentColor" d="M3.75 10.31 6.5 8.77l.04-.14-.04-.07h-.14l-.46-.03-1.57-.04-1.38-.07-1.33-.07-.34-.07L1 7.86l.03-.21.28-.18.4.03.89.07 1.33.08.97.06 1.43.16h.22l.03-.1-.07-.05-.06-.06-1.39-.92-1.48-.98-.79-.57-.42-.28-.2-.28-.1-.6.39-.41.52.04.12.03.52.4 1.12.86L6.2 6.04l.2.17.09-.06.01-.04-.1-.15-.76-1.46-.85-1.46-.37-.6-.1-.36a1 1 0 0 1-.06-.42l.42-.59.25-.07.6.08.22.2.36.84.58 1.3.9 1.77.29.53.14.47.04.14h.1v-.07l.07-1 .14-1.22.14-1.57.04-.45.23-.53.42-.28.36.15.28.41-.04.25-.16 1.08-.36 1.7-.21 1.14h.12l.14-.15.58-.76.97-1.2.42-.5.5-.51.32-.25h.6l.44.66-.2.68-.61.79-.52.65-.74 1-.45.8.04.05h.1l1.68-.36.9-.16 1.06-.18.5.23.05.22-.2.48-1.15.28-1.34.28-2 .46-.04.01.03.04.9.09.4.03h.94l1.77.14.46.28.27.37-.04.28-.72.37-.95-.23-2.24-.53-.76-.18h-.11v.06l.64.63L12 10.86l1.48 1.35.07.34-.18.28-.2-.03-1.29-.98-.5-.42-1.12-.95h-.07v.1l.25.38 1.37 2.05.07.63-.1.2-.36.14-.38-.08-.8-1.12-.85-1.26-.66-1.15-.07.05-.4 4.23-.19.21-.42.17-.35-.28-.2-.42.2-.87.23-1.12.18-.9.17-1.1.1-.36v-.03h-.1l-.84 1.16-1.27 1.72-1 1.07-.24.1-.42-.22.04-.39.22-.32 1.4-1.8.84-1.1.57-.64-.02-.07h-.04l-3.7 2.4-.66.09-.28-.28.03-.42.14-.14 1.12-.77z"/>
</symbol>`,`<symbol id="file-tree-builtin-docker" viewBox="0 0 16 16">
  <path fill="currentColor" d="M15.85 6.54c-.05-.04-.45-.36-1.31-.36q-.34 0-.68.06a2.7 2.7 0 0 0-1.14-1.79l-.23-.14-.15.23a3 3 0 0 0-.4 1q-.24 1.01.26 1.84c-.4.24-1.03.3-1.17.3H.5a.5.5 0 0 0-.5.52q-.01 1.46.46 2.83.55 1.5 1.6 2.18c.79.5 2.08.79 3.54.79q.96 0 1.94-.18a8 8 0 0 0 2.55-.97 7 7 0 0 0 1.73-1.5 10 10 0 0 0 1.7-3.06h.15a2.4 2.4 0 0 0 1.8-.7 2 2 0 0 0 .47-.74l.06-.2z"/>
  <path fill="currentColor" d="M1.48 7.36h1.4a.14.14 0 0 0 .14-.13V5.91q-.01-.12-.13-.14H1.48a.13.13 0 0 0-.13.14v1.32q.02.13.13.13m1.94 0h1.41a.14.14 0 0 0 .13-.13V5.91q-.01-.12-.13-.14h-1.4a.13.13 0 0 0-.13.14v1.32q0 .13.12.13m1.98 0h1.4q.13 0 .14-.13V5.91a.13.13 0 0 0-.14-.14H5.4q-.1.01-.12.14v1.32q0 .13.12.13m1.95 0h1.42q.1 0 .12-.13V5.91q0-.12-.12-.14H7.35q-.1.01-.12.14v1.32q.01.13.12.13M3.42 5.5h1.41c.07 0 .13-.08.13-.15V4.03a.13.13 0 0 0-.13-.14h-1.4q-.12 0-.13.14v1.31q0 .13.12.15m1.98 0h1.4c.08 0 .14-.08.14-.15V4.03q0-.13-.14-.14H5.4q-.1 0-.12.14v1.31q0 .13.12.15m1.95 0h1.42c.06 0 .12-.08.12-.15V4.03q-.01-.13-.12-.14H7.35q-.1 0-.12.14v1.31q.01.13.12.15m0-1.9h1.42q.1-.02.12-.14v-1.3Q8.88 2 8.77 2H7.35q-.1 0-.12.14v1.3q.01.13.12.14m1.97 3.78h1.4a.13.13 0 0 0 .14-.13V5.91q-.01-.12-.13-.14H9.32q-.1.01-.12.14v1.32q.01.13.12.13" opacity=".5"/>
</symbol>`,`<symbol id="file-tree-builtin-eslint" viewBox="0 0 16 16">
  <path fill="currentColor" d="M11.16 6.1 8.12 4.35a.3.3 0 0 0-.24 0L4.84 6.1a.3.3 0 0 0-.12.2v3.5q0 .14.12.22l3.04 1.74q.12.08.24 0l3.04-1.74a.2.2 0 0 0 .13-.22V6.3a.3.3 0 0 0-.13-.2" opacity=".5"/>
  <path fill="currentColor" d="m.1 7.69 3.63-6.3A.8.8 0 0 1 4.37 1h7.26c.26 0 .5.17.64.4l3.63 6.27a.8.8 0 0 1 0 .75l-3.63 6.24a.7.7 0 0 1-.64.34H4.37a.7.7 0 0 1-.64-.34L.1 8.41a.7.7 0 0 1 0-.72m3 3.02q.01.15.14.23l4.63 2.66q.13.06.26 0l4.63-2.66a.3.3 0 0 0 .14-.23V5.4a.3.3 0 0 0-.14-.23L8.13 2.52a.3.3 0 0 0-.26 0L3.24 5.17a.3.3 0 0 0-.14.23z"/>
</symbol>`,`<symbol id="file-tree-builtin-graphql" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M8 1a1.25 1.25 0 0 1 1.18 1.65l2.8 1.61q.33-.25.77-.26a1.25 1.25 0 0 1 .48 2.4v3.2a1.25 1.25 0 1 1-1.25 2.13l-2.8 1.62A1.25 1.25 0 0 1 8 15a1.25 1.25 0 0 1-1.18-1.65l-2.8-1.62q-.33.26-.77.27a1.25 1.25 0 0 1-.48-2.4V6.4a1.25 1.25 0 1 1 1.25-2.14l2.8-1.61A1.25 1.25 0 0 1 8 1M4.44 11.14l-.06.13 2.75 1.58a1.25 1.25 0 0 1 1.74 0l2.74-1.58-.05-.13zm3.89-7.68a1.3 1.3 0 0 1-.66 0L4.03 9.77q.37.3.45.78h7.04q.08-.48.45-.78zM4.38 4.73a1.24 1.24 0 0 1-1.02 1.76v3.02l.13.01 3.67-6.35-.03-.02zm4.46-1.56 3.67 6.35.13-.01V6.49a1.25 1.25 0 0 1-1.03-1.76L8.87 3.15z" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-nextjs" viewBox="0 0 16 16">
  <defs>
  <linearGradient id="a" x1="4.522" x2="14" y1="3.943" y2="16" gradientUnits="userSpaceOnUse">
  <stop stop-color="currentColor"/>
  <stop offset="1" stop-color="currentColor" stop-opacity="0"/>
  </linearGradient>
  </defs>
  <path fill="currentColor" d="M3 2h1.522v9.09H3z"/>
  <path fill="url(#a)" d="M4.903 2 15 15.075q-.565.5-1.195.925L4.522 3.943z"/>
  <path fill="currentColor" d="M12.172 2h-1.508v9.094h1.508z"/>
</symbol>`,`<symbol id="file-tree-builtin-npm" viewBox="0 0 16 16">
  <path fill="currentColor" d="M2 1a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V2a1 1 0 0 0-1-1z" class="vector" opacity=".2"/>
  <path fill="currentColor" d="M10.5 13H13V3H3v10h5V5.5h2.5z"/>
</symbol>`,`<symbol id="file-tree-builtin-oxc" viewBox="0 0 16 16">
  <path fill="currentColor" d="M9.5 1a.5.5 0 0 1 .5.5V3h3.5a.5.5 0 0 1 .38.83L10.5 7.69v1.44q.41.04.95-.16a4 4 0 0 0 .72-.35l.04-.03h.01a.5.5 0 0 1 .67.1l2 2.5a.5.5 0 0 1 0 .62c-.76.96-3.14 2.69-6.89 2.69s-6.13-1.73-6.89-2.69a.5.5 0 0 1 0-.62l2-2.5a.5.5 0 0 1 .67-.1l.05.03.16.09q.22.13.56.26.54.2.95.16V7.69L2.12 3.83A.5.5 0 0 1 2.5 3H6V1.5a.5.5 0 0 1 .5-.5zM7 3.5a.5.5 0 0 1-.5.5H3.6l2.78 3.17a.5.5 0 0 1 .12.33v2a.5.5 0 0 1-.28.45c-.7.35-1.5.15-2.02-.05a5 5 0 0 1-.58-.26l-1.46 1.84c.82.78 2.8 2.02 5.84 2.02s5.02-1.24 5.84-2.02l-1.46-1.83a5 5 0 0 1-.58.26c-.52.2-1.33.39-2.02.04a.5.5 0 0 1-.28-.45v-2a.5.5 0 0 1 .12-.33L12.4 4H9.5a.5.5 0 0 1-.5-.5V2H7z"/>
</symbol>`,`<symbol id="file-tree-builtin-postcss" viewBox="0 0 16 16">
  <path fill="currentColor" d="M14.5 8a6.5 6.5 0 0 0-5.9-6.47l5.42 8.93A7 7 0 0 0 14.5 8M2.88 12A6.5 6.5 0 0 0 8 14.5c2.08 0 3.93-.98 5.12-2.5zm8.62-1h1.68L11.5 8.24zm-1-.55a4 4 0 0 1-.7.55h.7zM8 5.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5M5.5 11h.7a4 4 0 0 1-.7-.55zm-2.68 0H4.5V8.24zm3.76-6.2A4 4 0 0 1 8 4.5q.76 0 1.42.3L8 2.46zM1.5 8q0 1.31.48 2.46L7.4 1.53A6.5 6.5 0 0 0 1.5 8m14 0a7.5 7.5 0 0 1-.99 3.72l-.01.03-.02.03A7.5 7.5 0 0 1 8 15.5a7.5 7.5 0 0 1-6.5-3.75l-.01-.03A7.5 7.5 0 1 1 15.5 8"/>
</symbol>`,`<symbol id="file-tree-builtin-prettier" viewBox="0 0 16 16">
  <path fill="currentColor" d="M6 12v1H4.93v-1zm1-2v1H2v-1zm6-4v1h-3V6zm-1-4v1H9V2z"/>
  <path fill="currentColor" d="M11.5 10v1H8v-1zM5 6v1H2V6zm5-2v1H9V4z" opacity=".8"/>
  <path fill="currentColor" d="M6 14v1H2v-1zm-.5-6v1H2V8zM13 4v1h-3V4zM4.93 2v1H2V2z" opacity=".6"/>
  <path fill="currentColor" d="M4.93 12v1H2v-1zM13 8v1H9V8zM5.5 4v1H2V4zM9 2v1H4.93V2z" opacity=".4"/>
</symbol>`,`<symbol id="file-tree-builtin-react" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8 6.65c.73 0 1.31.6 1.31 1.35S8.73 9.35 8 9.35 6.69 8.75 6.69 8 7.27 6.65 8 6.65"/>
  <path fill="currentColor" fill-rule="evenodd" d="M8 2.55c1.3-.99 2.59-1.34 3.5-.8.92.55 1.27 1.87 1.08 3.53C14.06 5.94 15 6.9 15 8s-.94 2.06-2.42 2.72c.19 1.65-.16 2.98-1.08 3.52-.91.55-2.2.2-3.5-.8-1.3 1-2.58 1.35-3.5.8-.91-.54-1.27-1.87-1.08-3.52C1.94 10.06 1 9.1 1 8s.94-2.06 2.42-2.72c-.19-1.66.17-2.98 1.08-3.52s2.2-.2 3.5.8M4.26 11.2c-.08 1.34.28 2.03.68 2.26s1.15.22 2.25-.52l.11-.09a12 12 0 0 1-1.24-1.39 11 11 0 0 1-1.8-.41zm7.47-.15q-.83.27-1.79.41-.6.8-1.24 1.4l.11.08c1.1.74 1.86.76 2.25.52.4-.23.76-.92.68-2.26zm-3.04.54a14 14 0 0 1-1.38 0q.34.38.69.7.35-.32.7-.7M8 5.29q-.76 0-1.47.1A13 13 0 0 0 5.07 8a14 14 0 0 0 1.46 2.62 13 13 0 0 0 2.94 0A13 13 0 0 0 10.93 8a14 14 0 0 0-1.46-2.62A13 13 0 0 0 8 5.3M4.64 9.18q-.15.5-.25.96.44.16.94.27a15 15 0 0 1-.7-1.23m6.73 0a15 15 0 0 1-.7 1.23q.5-.11.95-.27a10 10 0 0 0-.25-.96M3.44 6.26C2.27 6.86 1.87 7.53 1.87 8s.4 1.14 1.57 1.74l.13.07q.18-.88.55-1.81a12 12 0 0 1-.55-1.8q-.07.02-.13.06m8.99-.07A12 12 0 0 1 11.88 8q.36.94.55 1.8l.13-.06c1.17-.6 1.56-1.27 1.56-1.74s-.39-1.14-1.56-1.74zm-7.1-.6q-.5.11-.94.27.1.46.25.96a15 15 0 0 1 .69-1.23m5.34 0a15 15 0 0 1 .7 1.23q.14-.5.24-.96-.44-.15-.94-.27M7.18 3.06c-1.09-.74-1.85-.76-2.24-.52s-.76.92-.69 2.26l.01.15a11 11 0 0 1 1.8-.41q.6-.8 1.24-1.4zm3.88-.52c-.4-.24-1.15-.22-2.25.52l-.12.08q.65.6 1.25 1.4.96.15 1.8.41v-.14c.08-1.35-.28-2.04-.68-2.27M8 3.7a10 10 0 0 0-.7.7 14 14 0 0 1 1.4 0 10 10 0 0 0-.7-.7" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-sass" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M8.08 1.44c2.41-.91 4.96-.37 5.35 1.27.39 1.62-.92 3.56-2.6 4.25a5 5 0 0 1-3.26.35c-.58-.2-.92-.62-1-.85-.03-.09-.09-.24 0-.3.05-.03.08-.02.22.15s.7.6 1.75.48c2.78-.34 4.45-2.64 3.92-3.88-.37-.87-2.5-1.26-5.18.16C4.03 4.81 3.85 6.24 3.82 6.8c-.08 1.5 1.73 2.28 2.7 3.4q.04.03.07.08c.3-.12.7-.19 1.35-.2 1.58-.03 2.47 1.08 2.43 2.08-.03.78-.7 1.1-.82 1.13-.1.01-.14.02-.15-.06q-.03-.06.13-.15c.16-.09.42-.3.48-.72.05-.43-.24-1.44-1.76-1.63a3 3 0 0 0-1.33.08c.27.62.32 1.87-.29 2.83-.63 1-1.8 1.61-2.93 1.27-.37-.1-.93-.92-.45-2.05.46-1.07 2.4-2.12 2.66-2.26-.9-.83-3.08-1.95-3.4-3.65-.08-.49.13-1.65 1.46-2.98a12 12 0 0 1 4.11-2.52m-1.88 9.7c-.01.01-.9.47-1.52 1.17-.59.66-.75 1.48-.43 1.69.3.18 1-.04 1.51-.62a3 3 0 0 0 .5-.9q.2-.64.02-1.39z" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-stylelint" viewBox="0 0 16 16">
  <path fill="currentColor" d="M4 3v3.5l1.5-1L7 15 .5 6l1-1.5L0 3l2.5-2h1zm12 0-1.5 1.5 1 1.5L9 15l1.5-9.5 1.5 1V3l.5-2h1zm-8 8.5a.5.5 0 1 1 0 1 .5.5 0 0 1 0-1m0-3a.5.5 0 1 1 0 1 .5.5 0 0 1 0-1m0-3a.5.5 0 1 1 0 1 .5.5 0 0 1 0-1"/>
  <path fill="currentColor" d="M6.5 2.5V4l-2 1.5v-4zm5 3L9.5 4V2.5l2-1zM9 4H7V2.5h2z"/>
</symbol>`,`<symbol id="file-tree-builtin-svelte" viewBox="0 0 16 16">
  <path fill="currentColor" d="m3.98 3.7 3.36-2.08a4.5 4.5 0 0 1 5.9 1.23 4 4 0 0 1 .7 3.02q-.16.75-.58 1.4c.42.77.56 1.66.4 2.52a3.7 3.7 0 0 1-1.57 2.4l-.17.1-3.36 2.09a4.5 4.5 0 0 1-5.9-1.23 4 4 0 0 1-.66-1.44 4 4 0 0 1-.04-1.58 4 4 0 0 1 .58-1.4 4 4 0 0 1-.4-2.52 3.7 3.7 0 0 1 1.57-2.4zl3.36-2.08zm7.87 0a2.7 2.7 0 0 0-1.26-.95 2.7 2.7 0 0 0-1.6-.07 3 3 0 0 0-.52.2l-.16.09-3.36 2.08a2 2 0 0 0-.69.64 2 2 0 0 0-.36.86 2.3 2.3 0 0 0 .42 1.81A2.7 2.7 0 0 0 7.18 9.4q.28-.06.53-.2l.16-.09 1.28-.79.2-.09a.8.8 0 0 1 .87.31.7.7 0 0 1 .13.55.7.7 0 0 1-.24.4l-.08.05-3.36 2.08-.2.09a1 1 0 0 1-.49-.02 1 1 0 0 1-.38-.3 1 1 0 0 1-.13-.37v-.1l.01-.13-.13-.03a4 4 0 0 1-1.1-.5l-.2-.14-.18-.12-.07.18-.08.3a2.3 2.3 0 0 0 .43 1.82q.45.64 1.19.93.73.28 1.51.14l.16-.04q.27-.07.52-.2l.16-.09 3.36-2.08q.4-.25.69-.64.27-.4.36-.86a2.3 2.3 0 0 0-.42-1.82 2.7 2.7 0 0 0-1.27-.95 2.7 2.7 0 0 0-1.6-.08q-.27.07-.52.2l-.16.1-1.28.79-.2.09a1 1 0 0 1-.49-.03 1 1 0 0 1-.38-.29.7.7 0 0 1-.13-.54.7.7 0 0 1 .24-.4l.08-.06L9.33 4.4l.2-.1a.8.8 0 0 1 .87.32 1 1 0 0 1 .13.38v.22l.11.04q.6.18 1.12.5l.2.14.17.12.06-.19.08-.3a2.3 2.3 0 0 0-.42-1.81z"/>
</symbol>`,`<symbol id="file-tree-builtin-svg" viewBox="0 0 16 16">
  <path fill="currentColor" d="M5 7a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2z"/>
  <path fill="currentColor" d="M6 1a5 5 0 0 1 4.58 3H7a3 3 0 0 0-3 3v3.58A5 5 0 0 1 6 1" opacity=".5"/>
</symbol>`,`<symbol id="file-tree-builtin-svgo" viewBox="0 0 16 16">
  <path fill="currentColor" d="M9.43 4.8A.6.6 0 1 1 9.19 6l-.56.96a1.2 1.2 0 0 1 .32 1.58l.7.53a.89.89 0 1 1-.17.22l-.7-.52a1.2 1.2 0 0 1-1.4.25l-.56.87a.75.75 0 1 1-.57-.2 1 1 0 0 1 .32.05l.56-.87a1.2 1.2 0 0 1-.4-1.24l-1.2-.47a.56.56 0 1 1 .1-.28v.02l1.2.47a1.2 1.2 0 0 1 1.56-.55l.56-.97a.6.6 0 0 1-.15-.64.6.6 0 0 1 .63-.4"/>
  <path fill="currentColor" fill-rule="evenodd" d="M9.17 1q.16.63.27 1.26a6 6 0 0 1 1.61.67q.52-.38 1.08-.71l1.65 1.64q-.32.56-.68 1.05.48.78.72 1.67.6.09 1.18.25v2.32q-.55.15-1.11.24a6 6 0 0 1-.7 1.82q.31.44.59.91l-1.65 1.65-.85-.55a6 6 0 0 1-1.9.83q-.08.47-.2.95H6.84q-.12-.46-.2-.93a6 6 0 0 1-1.96-.81q-.39.27-.8.51l-1.65-1.65q.25-.43.53-.84a6 6 0 0 1-.75-1.9L1 9.16V6.83q.54-.14 1.09-.24a6 6 0 0 1 .77-1.74q-.33-.47-.63-.98l1.65-1.65q.54.32 1.03.68a6 6 0 0 1 1.66-.66q.1-.61.26-1.24zM7.96 3.73a4 4 0 0 0-1.74.36 4.5 4.5 0 0 0-2.3 2.3 4.4 4.4 0 0 0-.1 3.29l.03.06a4.4 4.4 0 0 0 2.4 2.47 4.4 4.4 0 0 0 3.48-.02l.03-.02a4.4 4.4 0 0 0 2.3-2.42l.06-.14a4.4 4.4 0 0 0-.2-3.4 4.4 4.4 0 0 0-2.13-2.07L9.47 4a4 4 0 0 0-1.51-.27" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-tailwind" viewBox="0 0 16 16">
  <path fill="currentColor" fill-rule="evenodd" d="M8 4Q5.2 4 4.5 6.67q1.05-1.34 2.45-1c.53.12.91.5 1.33.9C8.98 7.23 9.77 8 11.5 8q2.8 0 3.5-2.67-1.05 1.34-2.45 1c-.53-.12-.91-.5-1.33-.9C10.52 4.77 9.73 4 8 4M4.5 8Q1.7 8 1 10.67q1.05-1.34 2.45-1c.53.12.91.5 1.33.9C5.48 11.23 6.26 12 8 12q2.8 0 3.5-2.67-1.05 1.34-2.45 1c-.53-.12-.91-.5-1.33-.9C7.02 8.77 6.24 8 4.5 8" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-terraform" viewBox="0 0 16 16">
  <path fill="currentColor" d="M1 0v5.05l4.35 2.53V2.53zm9.18 5.34L5.83 2.82v5.05l4.35 2.53zm.47 5.06V5.34L15 2.82v5.05zm-.48 5.6-4.35-2.53V8.42l4.35 2.53z"/>
</symbol>`,`<symbol id="file-tree-builtin-vite" viewBox="0 0 16 16">
  <path fill="currentColor" d="M8.57 14.87c-.18.26-.55.11-.55-.22v-3.18l-.05-.27-.13-.22-.2-.15-.24-.06H4.29c-.26 0-.4-.32-.26-.55L6.08 7c.3-.46 0-1.1-.5-1.1H1.8c-.25 0-.4-.32-.25-.56l2.65-4.2A.3.3 0 0 1 4.46 1h7.9c.26 0 .4.32.26.55l-2.05 3.23c-.29.46 0 1.1.5 1.1h3.12c.26 0 .4.34.24.57z"/>
</symbol>`,`<symbol id="file-tree-builtin-vscode" viewBox="0 0 16 16">
  <path fill="currentColor" d="m5.11 9.68-2.4 1.84a.6.6 0 0 1-.75-.04l-.77-.7a.6.6 0 0 1 0-.87L3.28 8zm5.52-8.42a.51.51 0 0 1 .87.36V4.8L7.32 8 5.1 6.32z" opacity=".75"/>
  <path fill="currentColor" d="M11.1 14.99h.03zM1.96 4.52a.6.6 0 0 1 .75-.04l8.8 6.71v3.19a.51.51 0 0 1-.88.36L1.19 6.1a.6.6 0 0 1 0-.87z" opacity=".65"/>
  <path fill="currentColor" d="M11.62 14.91a.9.9 0 0 1-1-.17.51.51 0 0 0 .88-.36V1.62a.51.51 0 0 0-.87-.36.9.9 0 0 1 1-.17l2.87 1.39a.9.9 0 0 1 .5.8v9.44a.9.9 0 0 1-.5.8z"/>
</symbol>`,`<symbol id="file-tree-builtin-vue" viewBox="0 0 16 16">
  <path fill="currentColor" d="M9.62 2.25 8 5.02 6.38 2.25H1l7 12 7-12z" opacity=".5"/>
  <path fill="currentColor" d="M9.54 2.25 8 4.95l-1.54-2.7H4l4 7 4-7z"/>
</symbol>`,`<symbol id="file-tree-builtin-wasm" viewBox="0 0 16 16">
  <path fill="currentColor" d="M13 1a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V3a2 2 0 0 1 2-2h3a2 2 0 1 0 4 0z" class="subtract" opacity=".2"/>
  <path fill="currentColor" d="M4.64 11.4h.02l.8-3.4h.91l.73 3.45L7.88 8h.96l-1.25 5h-.97L5.9 9.6 5.1 13h-1L3 8h.98z"/>
  <path fill="currentColor" fill-rule="evenodd" d="M13 13h-1.02l-.33-1.11H9.9L9.64 13h-.97l1.26-5h1.54zm-2.49-3.77-.42 1.84h1.32l-.49-1.84z" clip-rule="evenodd"/>
</symbol>`,`<symbol id="file-tree-builtin-webpack" viewBox="0 0 16 16">
  <path fill="currentColor" d="M14.1 11.79 8.26 15v-2.5l3.64-1.94zm.4-.35V4.73l-2.14 1.2v4.3zm-12.6.35L7.74 15v-2.5L4.1 10.56zm-.4-.35V4.73l2.14 1.2v4.3zm.25-7.15 6-3.29v2.42L3.9 5.47l-.03.01zm12.5 0L8.25 1v2.42l3.85 2.05.03.01z" class="bg" opacity=".4"/>
  <path fill="currentColor" d="m7.74 11.93-3.59-1.92v-3.8l3.6 2.02zm.52 0 3.59-1.92v-3.8l-3.6 2.02zM4.4 5.77 8 3.85l3.6 1.93L8 7.8z" class="fg"/>
</symbol>`,`<symbol id="file-tree-builtin-yml" viewBox="0 0 16 16">
  <path fill="currentColor" d="M7.5 2A1.5 1.5 0 0 1 9 3.5v3A1.5 1.5 0 0 1 7.5 8h-2v2A1.5 1.5 0 0 0 7 11.5v-1A1.5 1.5 0 0 1 8.5 9h5a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.5 1.5h-5A1.5 1.5 0 0 1 7 13.5v-1A2.5 2.5 0 0 1 4.5 10V8h-2A1.5 1.5 0 0 1 1 6.5v-3A1.5 1.5 0 0 1 2.5 2zm1 8a.5.5 0 0 0-.5.5v3a.5.5 0 0 0 .5.5h5a.5.5 0 0 0 .5-.5v-3a.5.5 0 0 0-.5-.5zm-6-7a.5.5 0 0 0-.5.5v3a.5.5 0 0 0 .5.5h5a.5.5 0 0 0 .5-.5v-3a.5.5 0 0 0-.5-.5z"/>
</symbol>`,`<symbol id="file-tree-builtin-zig" viewBox="0 0 16 16">
  <path fill="currentColor" d="m14.73 1.5-7.29 8.82h4.17l-1.73 2.04H5.76L1.27 14.5l7.3-8.91H4.39l1.73-2.05h4.12z"/>
  <path fill="currentColor" d="M5.21 3.54 3.56 5.6h-.55v4.73h.83L2.1 12.36H1V3.54zm9.79 0v8.82h-4.3l1.74-2.04h.55V5.68h-.83l1.74-2.14z"/>
</symbol>`];function E7(J,Q){if(Q.length===0)return J;return J.replace("</svg>",`
  ${Q.join(`
  `)}
</svg>`)}var V7=E7(`<svg data-icon-sprite aria-hidden="true" width="0" height="0">
  <symbol id="file-tree-icon-chevron" viewBox="0 0 16 16">
    <path d="M12.4697 5.46973C12.7626 5.17684 13.2374 5.17684 13.5303 5.46973C13.8232 5.76262 13.8232 6.23738 13.5303 6.53028L8.53028 11.5303C8.23738 11.8232 7.76262 11.8232 7.46973 11.5303L2.46973 6.53028C2.17684 6.23738 2.17684 5.76262 2.46973 5.46973C2.76262 5.17684 3.23738 5.17684 3.53028 5.46973L8 9.93946L12.4697 5.46973Z" fill="currentcolor"/>
  </symbol>
  <symbol id="file-tree-icon-dot" viewBox="0 0 6 6">
    <circle cx="3" cy="3" r="3" />
  </symbol>
  <symbol id="file-tree-icon-file" viewBox="0 0 16 16">
    <path fill="currentColor" d="M8 1v3a3 3 0 0 0 3 3h3v5.5a2.5 2.5 0 0 1-2.5 2.5h-7A2.5 2.5 0 0 1 2 12.5v-9A2.5 2.5 0 0 1 4.5 1z" class="bg" opacity=".5"/>
    <path fill="currentColor" d="M9.5 1a.5.5 0 0 1 .354.146l4 4A.5.5 0 0 1 14 5.5V6h-3a2 2 0 0 1-2-2V1z" class="fg"/>
  </symbol>
  <symbol id="file-tree-icon-lock" viewBox="0 0 16 16">
    <path fill="currentcolor" d="M4 5.336V4a4 4 0 1 1 8 0v1.336c1.586.54 2 1.843 2 4.664v1c0 4.118-.883 5-5 5H7c-4.117 0-5-.883-5-5v-1c0-2.821.414-4.124 2-4.664M5.5 4v1.054Q6.166 4.998 7 5h2q.834-.002 1.5.054V4a2.5 2.5 0 0 0-5 0m-2 6v1c0 .995.055 1.692.167 2.193.107.483.246.686.35.79s.307.243.79.35c.5.112 1.198.167 2.193.167h2c.995 0 1.692-.055 2.193-.166.483-.108.686-.247.79-.35.104-.105.243-.308.35-.791.112-.5.167-1.198.167-2.193v-1c0-.995-.055-1.692-.166-2.193-.108-.483-.247-.686-.35-.79-.105-.104-.308-.243-.791-.35C10.693 6.555 9.995 6.5 9 6.5H7c-.995 0-1.692.055-2.193.167-.483.107-.686.246-.79.35s-.243.307-.35.79C3.555 8.307 3.5 9.005 3.5 10" />
  </symbol>
  <symbol id="file-tree-icon-ellipsis" viewBox="0 0 16 16">
    <path d="M5 8.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0M9.5 8.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0M14 8.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0" />
  </symbol>
</svg>`,JQ),XQ={minimal:`<svg data-icon-sprite aria-hidden="true" width="0" height="0">
  <symbol id="file-tree-icon-chevron" viewBox="0 0 16 16">
    <path d="M12.4697 5.46973C12.7626 5.17684 13.2374 5.17684 13.5303 5.46973C13.8232 5.76262 13.8232 6.23738 13.5303 6.53028L8.53028 11.5303C8.23738 11.8232 7.76262 11.8232 7.46973 11.5303L2.46973 6.53028C2.17684 6.23738 2.17684 5.76262 2.46973 5.46973C2.76262 5.17684 3.23738 5.17684 3.53028 5.46973L8 9.93946L12.4697 5.46973Z" fill="currentcolor"/>
  </symbol>
  <symbol id="file-tree-icon-dot" viewBox="0 0 6 6">
    <circle cx="3" cy="3" r="3" />
  </symbol>
  <symbol id="file-tree-icon-file" viewBox="0 0 16 16">
    <path fill="currentColor" d="M8 1v3a3 3 0 0 0 3 3h3v5.5a2.5 2.5 0 0 1-2.5 2.5h-7A2.5 2.5 0 0 1 2 12.5v-9A2.5 2.5 0 0 1 4.5 1z" class="bg" opacity=".5"/>
    <path fill="currentColor" d="M9.5 1a.5.5 0 0 1 .354.146l4 4A.5.5 0 0 1 14 5.5V6h-3a2 2 0 0 1-2-2V1z" class="fg"/>
  </symbol>
  <symbol id="file-tree-icon-lock" viewBox="0 0 16 16">
    <path fill="currentcolor" d="M4 5.336V4a4 4 0 1 1 8 0v1.336c1.586.54 2 1.843 2 4.664v1c0 4.118-.883 5-5 5H7c-4.117 0-5-.883-5-5v-1c0-2.821.414-4.124 2-4.664M5.5 4v1.054Q6.166 4.998 7 5h2q.834-.002 1.5.054V4a2.5 2.5 0 0 0-5 0m-2 6v1c0 .995.055 1.692.167 2.193.107.483.246.686.35.79s.307.243.79.35c.5.112 1.198.167 2.193.167h2c.995 0 1.692-.055 2.193-.166.483-.108.686-.247.79-.35.104-.105.243-.308.35-.791.112-.5.167-1.198.167-2.193v-1c0-.995-.055-1.692-.166-2.193-.108-.483-.247-.686-.35-.79-.105-.104-.308-.243-.791-.35C10.693 6.555 9.995 6.5 9 6.5H7c-.995 0-1.692.055-2.193.167-.483.107-.686.246-.79.35s-.243.307-.35.79C3.555 8.307 3.5 9.005 3.5 10" />
  </symbol>
  <symbol id="file-tree-icon-ellipsis" viewBox="0 0 16 16">
    <path d="M5 8.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0M9.5 8.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0M14 8.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0" />
  </symbol>
</svg>`,standard:V7,complete:E7(V7,QQ)},ZQ={".babelrc":"babel",".babelrc.json":"babel",".bash_profile":"bash",".bashrc":"bash",".browserslistrc":"browserslist",".dockerignore":"docker",".eslintignore":"eslint",".eslintrc":"eslint",".eslintrc.cjs":"eslint",".eslintrc.js":"eslint",".eslintrc.json":"eslint",".eslintrc.yaml":"eslint",".eslintrc.yml":"eslint",".gitattributes":"git",".gitignore":"git",".gitkeep":"git",".gitmodules":"git",".oxlintrc.json":"oxc",".postcssrc":"postcss",".postcssrc.json":"postcss",".postcssrc.yaml":"postcss",".postcssrc.yml":"postcss",".prettierignore":"prettier",".prettierrc":"prettier",".prettierrc.cjs":"prettier",".prettierrc.js":"prettier",".prettierrc.json":"prettier",".prettierrc.mjs":"prettier",".prettierrc.toml":"prettier",".prettierrc.yaml":"prettier",".prettierrc.yml":"prettier",".stylelintignore":"stylelint",".stylelintrc":"stylelint",".stylelintrc.cjs":"stylelint",".stylelintrc.js":"stylelint",".stylelintrc.json":"stylelint",".stylelintrc.mjs":"stylelint",".stylelintrc.yaml":"stylelint",".stylelintrc.yml":"stylelint",".terraform.lock.hcl":"terraform",".zprofile":"bash",".zshenv":"bash",".zshrc":"bash","babel.config.cjs":"babel","babel.config.js":"babel","babel.config.json":"babel","babel.config.mjs":"babel","biome.json":"biome","biome.jsonc":"biome","bootstrap.bundle.js":"bootstrap","bootstrap.bundle.min.js":"bootstrap","bootstrap.css":"bootstrap","bootstrap.js":"bootstrap","bootstrap.min.css":"bootstrap","bootstrap.min.js":"bootstrap","bun.lock":"bun","bun.lockb":"bun","bunfig.toml":"bun","claude.md":"claude","compose.yaml":"docker","compose.yml":"docker","docker-compose.override.yml":"docker","docker-compose.yaml":"docker","docker-compose.yml":"docker",dockerfile:"docker","eslint.config.cjs":"eslint","eslint.config.js":"eslint","eslint.config.mjs":"eslint","eslint.config.mts":"eslint","eslint.config.ts":"eslint",gemfile:"ruby","next.config.js":"nextjs","next.config.mjs":"nextjs","next.config.mts":"nextjs","next.config.ts":"nextjs","postcss.config.cjs":"postcss","postcss.config.js":"postcss","postcss.config.mjs":"postcss","postcss.config.ts":"postcss","prettier.config.cjs":"prettier","prettier.config.js":"prettier","prettier.config.mjs":"prettier",rakefile:"ruby","readme.md":"markdown","stylelint.config.cjs":"stylelint","stylelint.config.js":"stylelint","stylelint.config.mjs":"stylelint","svgo.config.cjs":"svgo","svgo.config.js":"svgo","svgo.config.mjs":"svgo","svgo.config.ts":"svgo","tailwind.config.cjs":"tailwind","tailwind.config.js":"tailwind","tailwind.config.mjs":"tailwind","tailwind.config.ts":"tailwind","vite.config.js":"vite","vite.config.mjs":"vite","vite.config.mts":"vite","vite.config.ts":"vite","webpack.config.babel.js":"webpack","webpack.config.cjs":"webpack","webpack.config.js":"webpack","webpack.config.mjs":"webpack","webpack.config.ts":"webpack"},YQ={"7z":"zip",astro:"astro",AUTHORS:"text",avif:"image",bash:"bash",bmp:"image",bz2:"zip",c:"c",cc:"cpp",cfg:"text",CHANGELOG:"text",cjs:"javascript","code-workspace":"vscode",conf:"text",CONTRIBUTORS:"text",cpp:"cpp",csh:"bash",css:"css",csv:"table",cts:"typescript",cxx:"cpp",db:"database",editorconfig:"text",env:"text","env.development":"text","env.local":"text","env.production":"text",eot:"font",erb:"ruby",fish:"bash",gemspec:"ruby",gif:"image",go:"go",gql:"graphql",graphql:"graphql",gz:"zip",h:"c",hh:"cpp",hpp:"cpp",htm:"html",html:"html",hxx:"cpp",icns:"image",ico:"image",ini:"text",inl:"cpp",jar:"zip",jpeg:"image",jpg:"image",js:"javascript",json:"json",json5:"json",jsonc:"json",jsonl:"json",jsx:"javascript",ksh:"bash",less:"css",LICENSE:"text",log:"text",markdown:"markdown",mcp:"mcp",md:"markdown",mdx:"markdown","mdx.tsx":"markdown",mjs:"javascript",mm:"cpp",mts:"typescript",ods:"table",otf:"font",png:"image",postcss:"css",py:"python",pyi:"python",pyw:"python",pyx:"python",rake:"ruby",rar:"zip",rb:"ruby",rs:"rust",rst:"text",rtf:"text",sass:"css",scss:"css",sh:"bash",sql:"database",sqlite:"database",sqlite3:"database",styl:"css",svelte:"svelte",svg:"svg",swift:"swift",tar:"zip",tf:"terraform",tfstate:"terraform",tfvars:"terraform",tgz:"zip",tif:"image",tiff:"image",ts:"typescript",tsv:"table",tsx:"typescript",ttf:"font",txt:"text",vue:"vue",war:"zip",wasm:"wasm",wast:"wasm",wat:"wasm",webp:"image",woff:"font",woff2:"font",xhtml:"html",xls:"table",xlsx:"table",xz:"zip",yaml:"yml",yml:"yml",zig:"zig",zip:"zip",zsh:"bash"},WQ={jsx:"react",sass:"sass",scss:"sass",tsx:"react"},R7=new Set(["bash","c","cpp","css","database","default","font","git","go","html","image","javascript","json","markdown","mcp","python","ruby","rust","swift","table","text","typescript","zip"]),qQ=new Set(["complete"]);function D7(J){return XQ[J==="none"?"minimal":J]}function T7(J){return`file-tree-builtin-${J}`}function C7(J){return J!=="none"&&qQ.has(J)}function b7(J,Q,X){if(J==="minimal"||J==="none")return;let Z=J==="complete",Y=ZQ[Q.toLowerCase()];if(Y!=null){if(Z||R7.has(Y))return Y}for(let W of X){if(Z){let G=WQ[W];if(G!=null)return G}let q=YQ[W];if(q!=null){if(Z||R7.has(q))return q}}return"default"}var I1="file-tree-container",F3="data-file-tree-style",h4="data-file-tree-unsafe-css",w7="data-file-tree-scrollbar-measure",l4="data-file-tree-scrollbar-gutter-measured",N7="--trees-scrollbar-gutter-measured",d4="f::",H3="header",u1="context-menu",a3="context-menu-trigger";function GQ(J){return J.spriteSheet!=null||J.remap!=null||J.byFileName!=null||J.byFileExtension!=null||J.byFileNameContains!=null}function c1(J){if(J==null)return{set:"complete",colored:!0};if(typeof J==="string")return{set:J,colored:!0};return{...J,set:J.set??(GQ(J)?"none":"complete"),colored:J.colored??!0}}var n3={compact:{itemHeight:24,factor:0.8},default:{itemHeight:30,factor:1},relaxed:{itemHeight:36,factor:1.2}};function y7(J,Q){if(typeof J==="number")return{itemHeight:Q??n3.default.itemHeight,factor:J};let X=n3[J??"default"];return{itemHeight:Q??X.itemHeight,factor:X.factor}}var t3=n3.default.itemHeight,v7=10,e3=420;var i4=`@layer base, theme, unsafe;

@layer base {
  :host {
    /*
      CSS variables use a fallback stack to ensure user and theme colors slot
      in with ease. User colors take precedence over theme colors, which take
      precedence over defaults.

      Fallback order:

      1. --trees-*-override (explicit)
      2. --trees-theme-* (e.g. Shiki/VS Code tokens)
      3. defaults

      Theme variable names mirror Shiki/VS Code theme file JSON tokens.

      // Available CSS Color Overrides
      --trees-fg-override
      --trees-fg-muted-override
      --trees-bg-override
      --trees-bg-muted-override
      --trees-accent-override
      --trees-border-color-override

      --trees-focus-ring-color-override
      --trees-focus-ring-width-override
      --trees-focus-ring-offset-override

      --trees-search-fg-override
      --trees-search-font-weight-override
      --trees-search-bg-override

      --trees-selected-fg-override
      --trees-selected-bg-override
      --trees-selected-focused-border-color-override

      // Git Status Color Overrides
      --trees-status-added-override
      --trees-status-ignored-override
      --trees-status-modified-override
      --trees-status-renamed-override
      --trees-status-untracked-override
      --trees-status-deleted-override
      --trees-git-added-color-override
      --trees-git-ignored-color-override
      --trees-git-modified-color-override
      --trees-git-renamed-color-override
      --trees-git-untracked-color-override
      --trees-git-deleted-color-override

      // Built-in File Icon Color Overrides
      --trees-file-icon-color
      --trees-file-icon-color-astro
      --trees-file-icon-color-babel
      --trees-file-icon-color-bash
      --trees-file-icon-color-biome
      --trees-file-icon-color-bootstrap
      --trees-file-icon-color-browserslist
      --trees-file-icon-color-bun
      --trees-file-icon-color-c
      --trees-file-icon-color-cpp
      --trees-file-icon-color-claude
      --trees-file-icon-color-css
      --trees-file-icon-color-database
      --trees-file-icon-color-default
      --trees-file-icon-color-docker
      --trees-file-icon-color-eslint
      --trees-file-icon-color-git
      --trees-file-icon-color-go
      --trees-file-icon-color-graphql
      --trees-file-icon-color-html
      --trees-file-icon-color-image
      --trees-file-icon-color-javascript
      --trees-file-icon-color-json
      --trees-file-icon-color-markdown
      --trees-file-icon-color-mcp
      --trees-file-icon-color-npm
      --trees-file-icon-color-oxc
      --trees-file-icon-color-postcss
      --trees-file-icon-color-prettier
      --trees-file-icon-color-python
      --trees-file-icon-color-react
      --trees-file-icon-color-ruby
      --trees-file-icon-color-rust
      --trees-file-icon-color-sass
      --trees-file-icon-color-svg
      --trees-file-icon-color-svelte
      --trees-file-icon-color-svgo
      --trees-file-icon-color-swift
      --trees-file-icon-color-table
      --trees-file-icon-color-text
      --trees-file-icon-color-tailwind
      --trees-file-icon-color-terraform
      --trees-file-icon-color-typescript
      --trees-file-icon-color-vite
      --trees-file-icon-color-vscode
      --trees-file-icon-color-vue
      --trees-file-icon-color-wasm
      --trees-file-icon-color-webpack
      --trees-file-icon-color-yml
      --trees-file-icon-color-zig
      --trees-file-icon-color-zip

      // Density
      //
      // A unitless scale factor for padding, gaps, and indentation. Usually
      // set via \`density\` on useFileTree. Individual overrides take precedence.
      //
      //   Compact: 0.8
      //   Default: 1
      //   Relaxed: 1.2
      //
      --trees-density-override

      // Available CSS Layout Overrides
      --trees-gap-override
      --trees-border-radius-override
      --trees-font-family-override
      --trees-font-size-override
      --trees-font-weight-regular-override
      --trees-font-weight-semibold-override
      --trees-level-gap-override
      --trees-item-padding-x-override
      --trees-item-margin-x-override
      --trees-item-row-gap-override
      --trees-icon-width-override
      --trees-icon-nudge-override
      --trees-scrollbar-gutter-override
      --trees-padding-inline-override
    */

    --trees-accent: var(--trees-accent-override, #009fff);
    --trees-fg: var(
      --trees-fg-override,
      var(--trees-theme-sidebar-fg, light-dark(#6c6c71, #adadb1))
    );
    --trees-fg-muted: var(
      --trees-fg-muted-override,
      var(--trees-theme-sidebar-header-fg, light-dark(#84848a, #84848a))
    );
    --trees-bg: var(
      --trees-bg-override,
      var(--trees-theme-sidebar-bg, light-dark(#f8f8f8, #141415))
    );
    /* var(--trees-theme-list-hover-bg, light-dark(#dfebff59, #19283c59)) */
    --trees-bg-muted: var(
      --trees-bg-muted-override,
      var(
        --trees-theme-list-hover-bg,
        light-dark(
          color-mix(
            in lab,
            var(--trees-accent) var(--trees-bg-alpha-light, 8%),
            var(--trees-bg)
          ),
          color-mix(
            in lab,
            var(--trees-accent) var(--trees-bg-alpha-dark, 10%),
            var(--trees-bg)
          )
        )
      )
    );
    --trees-input-bg: var(
      --trees-input-bg-override,
      light-dark(#f8f8f8, #070707)
    );

    --trees-added-light: #16a994;
    --trees-added-dark: #00cab1;
    --trees-ignored-light: #adadb1;
    --trees-ignored-dark: #4a4a4e;
    --trees-modified-light: #1ca1c7;
    --trees-modified-dark: #08c0ef;
    --trees-renamed-light: #d5a910;
    --trees-renamed-dark: #ffd452;
    --trees-untracked-light: #16a994;
    --trees-untracked-dark: #00cab1;
    --trees-deleted-light: #ff2e3f;
    --trees-deleted-dark: #ff6762;

    --trees-border-color: var(
      --trees-border-color-override,
      var(--trees-theme-sidebar-border, light-dark(#eeeeef, #070707))
    );
    --trees-indent-guide-bg: var(
      --trees-indent-guide-bg-override,
      color-mix(in lab, var(--trees-fg-muted) 25%, transparent)
    );
    --trees-density: var(--trees-density-override, 1);
    --trees-border-radius: var(
      --trees-border-radius-override,
      calc(6px * var(--trees-density))
    );

    --trees-font-family: var(--trees-font-family-override, system-ui);
    --trees-font-size: var(--trees-font-size-override, 13px);
    --trees-font-weight-regular: var(--trees-font-weight-regular-override, 400);
    --trees-font-weight-semibold: var(
      --trees-font-weight-semibold-override,
      600
    );

    --trees-focus-ring-color: var(
      --trees-focus-ring-color-override,
      var(--trees-theme-focus-ring, var(--trees-accent))
    );
    --trees-focus-ring-width: var(--trees-focus-ring-width-override, 1px);
    --trees-focus-ring-offset: var(--trees-focus-ring-offset-override, -1px);

    --trees-search-fg: var(
      --trees-search-fg-override,
      var(--trees-theme-input-fg, var(--trees-fg))
    );
    --trees-search-font-weight: var(--trees-search-font-weight-override, 600);
    --trees-search-bg: var(
      --trees-search-bg-override,
      var(--trees-theme-input-bg, var(--trees-input-bg))
    );

    --trees-scrollbar-thumb: var(
      --trees-scrollbar-thumb-override,
      var(
        --trees-theme-scrollbar-thumb,
        color-mix(in lab, var(--trees-fg) 25%, var(--trees-bg))
      )
    );

    --trees-selected-fg: var(
      --trees-selected-fg-override,
      var(--trees-theme-list-active-selection-fg, var(--trees-fg))
    );
    --trees-selected-bg: var(
      --trees-selected-bg-override,
      var(
        --trees-theme-list-active-selection-bg,
        light-dark(
          color-mix(in lab, var(--trees-accent) 12%, var(--trees-bg)),
          color-mix(in lab, var(--trees-accent) 15%, var(--trees-bg))
        )
      )
    );
    --trees-selected-focused-border-color: var(
      --trees-selected-focused-border-color-override,
      var(--trees-theme-focus-ring, var(--trees-accent))
    );

    /* Git status (e.g. from Shiki theme gitDecoration.*) */
    --trees-status-added: var(
      --trees-status-added-override,
      var(
        --trees-theme-git-added-fg,
        light-dark(var(--trees-added-light), var(--trees-added-dark))
      )
    );
    --trees-status-ignored: var(
      --trees-status-ignored-override,
      var(
        --trees-theme-git-ignored-fg,
        light-dark(var(--trees-ignored-light), var(--trees-ignored-dark))
      )
    );
    --trees-status-modified: var(
      --trees-status-modified-override,
      var(
        --trees-theme-git-modified-fg,
        light-dark(var(--trees-modified-light), var(--trees-modified-dark))
      )
    );
    --trees-status-renamed: var(
      --trees-status-renamed-override,
      var(
        --trees-theme-git-renamed-fg,
        light-dark(var(--trees-renamed-light), var(--trees-renamed-dark))
      )
    );
    --trees-status-untracked: var(
      --trees-status-untracked-override,
      var(
        --trees-theme-git-untracked-fg,
        light-dark(var(--trees-untracked-light), var(--trees-untracked-dark))
      )
    );
    --trees-status-deleted: var(
      --trees-status-deleted-override,
      var(
        --trees-theme-git-deleted-fg,
        light-dark(var(--trees-deleted-light), var(--trees-deleted-dark))
      )
    );
    --trees-git-modified-color: var(
      --trees-git-modified-color-override,
      var(--trees-status-modified)
    );
    --trees-git-added-color: var(
      --trees-git-added-color-override,
      var(--trees-status-added)
    );
    --trees-git-ignored-color: var(
      --trees-git-ignored-color-override,
      var(--trees-status-ignored)
    );
    --trees-git-deleted-color: var(
      --trees-git-deleted-color-override,
      var(--trees-status-deleted)
    );
    --trees-git-renamed-color: var(
      --trees-git-renamed-color-override,
      var(--trees-status-renamed)
    );
    --trees-git-untracked-color: var(
      --trees-git-untracked-color-override,
      var(--trees-status-untracked)
    );

    --trees-icon-gray: light-dark(#84848a, #adadb1);
    --trees-icon-red: light-dark(#d52c36, #ff6762);
    --trees-icon-vermilion: light-dark(#ff8c5b, #d5512f);
    --trees-icon-orange: light-dark(#d47628, #ffa359);
    --trees-icon-yellow: light-dark(#d5a910, #ffd452);
    --trees-icon-green: light-dark(#199f43, #5ecc71);
    --trees-icon-teal: light-dark(#17a5af, #64d1db);
    --trees-icon-cyan: light-dark(#1ca1c7, #68cdf2);
    --trees-icon-blue: light-dark(#1a85d4, #69b1ff);
    --trees-icon-indigo: light-dark(#693acf, #9d6afb);
    --trees-icon-purple: light-dark(#a631be, #d568ea);
    --trees-icon-pink: light-dark(#d32a61, #ff678d);
    --trees-icon-mauve: light-dark(#594c5b, #79697b);

    --trees-file-icon-color-default: var(
      --trees-file-icon-color,
      var(--trees-icon-gray)
    );
    --trees-file-icon-color-astro: var(
      --trees-file-icon-color,
      var(--trees-icon-purple)
    );
    --trees-file-icon-color-babel: var(
      --trees-file-icon-color,
      var(--trees-icon-yellow)
    );
    --trees-file-icon-color-bash: var(
      --trees-file-icon-color,
      var(--trees-icon-green)
    );
    --trees-file-icon-color-biome: var(
      --trees-file-icon-color,
      var(--trees-icon-blue)
    );
    --trees-file-icon-color-bootstrap: var(
      --trees-file-icon-color,
      var(--trees-icon-indigo)
    );
    --trees-file-icon-color-browserslist: var(
      --trees-file-icon-color,
      var(--trees-icon-yellow)
    );
    --trees-file-icon-color-bun: var(
      --trees-file-icon-color,
      var(--trees-icon-mauve)
    );
    --trees-file-icon-color-c: var(
      --trees-file-icon-color,
      var(--trees-icon-blue)
    );
    --trees-file-icon-color-cpp: var(
      --trees-file-icon-color,
      var(--trees-icon-blue)
    );
    --trees-file-icon-color-claude: var(
      --trees-file-icon-color,
      var(--trees-icon-orange)
    );
    --trees-file-icon-color-css: var(
      --trees-file-icon-color,
      var(--trees-icon-indigo)
    );
    --trees-file-icon-color-database: var(
      --trees-file-icon-color,
      var(--trees-icon-purple)
    );
    --trees-file-icon-color-docker: var(
      --trees-file-icon-color,
      var(--trees-icon-blue)
    );
    --trees-file-icon-color-eslint: var(
      --trees-file-icon-color,
      var(--trees-icon-indigo)
    );
    --trees-file-icon-color-git: var(
      --trees-file-icon-vermilion,
      var(--trees-icon-vermilion)
    );
    --trees-file-icon-color-go: var(
      --trees-file-icon-color,
      var(--trees-icon-cyan)
    );
    --trees-file-icon-color-graphql: var(
      --trees-file-icon-color,
      var(--trees-icon-pink)
    );
    --trees-file-icon-color-html: var(
      --trees-file-icon-color,
      var(--trees-icon-orange)
    );
    --trees-file-icon-color-image: var(
      --trees-file-icon-color,
      var(--trees-icon-pink)
    );
    --trees-file-icon-color-javascript: var(
      --trees-file-icon-color,
      var(--trees-icon-yellow)
    );
    --trees-file-icon-color-json: var(
      --trees-file-icon-color,
      var(--trees-icon-orange)
    );
    --trees-file-icon-color-markdown: var(
      --trees-file-icon-color,
      var(--trees-icon-green)
    );
    --trees-file-icon-color-mcp: var(
      --trees-file-icon-color,
      var(--trees-icon-teal)
    );
    --trees-file-icon-color-npm: var(
      --trees-file-icon-color,
      var(--trees-icon-red)
    );
    --trees-file-icon-color-oxc: var(
      --trees-file-icon-cyan,
      var(--trees-icon-cyan)
    );
    --trees-file-icon-color-postcss: var(
      --trees-file-icon-color,
      var(--trees-icon-red)
    );
    --trees-file-icon-color-prettier: var(
      --trees-file-icon-color,
      var(--trees-icon-teal)
    );
    --trees-file-icon-color-python: var(
      --trees-file-icon-color,
      var(--trees-icon-blue)
    );
    --trees-file-icon-color-react: var(
      --trees-file-icon-color,
      var(--trees-icon-cyan)
    );
    --trees-file-icon-color-ruby: var(
      --trees-file-icon-color,
      var(--trees-icon-red)
    );
    --trees-file-icon-color-rust: var(
      --trees-file-icon-color,
      var(--trees-icon-orange)
    );
    --trees-file-icon-color-sass: var(
      --trees-file-icon-color,
      var(--trees-icon-pink)
    );
    --trees-file-icon-color-svg: var(
      --trees-file-icon-color,
      var(--trees-icon-orange)
    );
    --trees-file-icon-color-svelte: var(
      --trees-file-icon-color,
      var(--trees-icon-red)
    );
    --trees-file-icon-color-svgo: var(
      --trees-file-icon-color,
      var(--trees-icon-green)
    );
    --trees-file-icon-color-swift: var(
      --trees-file-icon-color,
      var(--trees-icon-orange)
    );
    --trees-file-icon-color-table: var(
      --trees-file-icon-color,
      var(--trees-icon-teal)
    );
    --trees-file-icon-color-text: var(
      --trees-file-icon-color,
      var(--trees-icon-gray)
    );
    --trees-file-icon-color-tailwind: var(
      --trees-file-icon-color,
      var(--trees-icon-cyan)
    );
    --trees-file-icon-color-terraform: var(
      --trees-file-icon-color,
      var(--trees-icon-indigo)
    );
    --trees-file-icon-color-typescript: var(
      --trees-file-icon-color,
      var(--trees-icon-blue)
    );
    --trees-file-icon-color-vite: var(
      --trees-file-icon-color,
      var(--trees-icon-purple)
    );
    --trees-file-icon-color-vscode: var(
      --trees-file-icon-color,
      var(--trees-icon-blue)
    );
    --trees-file-icon-color-vue: var(
      --trees-file-icon-color,
      var(--trees-icon-green)
    );
    --trees-file-icon-color-wasm: var(
      --trees-file-icon-color,
      var(--trees-icon-indigo)
    );
    --trees-file-icon-color-webpack: var(
      --trees-file-icon-color,
      var(--trees-icon-blue)
    );
    --trees-file-icon-color-yml: var(
      --trees-file-icon-color,
      var(--trees-icon-red)
    );
    --trees-file-icon-color-zig: var(
      --trees-file-icon-color,
      var(--trees-icon-orange)
    );
    --trees-file-icon-color-zip: var(
      --trees-file-icon-color,
      var(--trees-icon-orange)
    );

    --trees-level-gap: var(
      --trees-level-gap-override,
      calc(8px * var(--trees-density))
    );
    --trees-item-padding-x: var(
      --trees-item-padding-x-override,
      calc(8px * var(--trees-density))
    );
    --trees-item-margin-x: var(
      --trees-item-margin-x-override,
      calc(2px * var(--trees-density))
    );
    --trees-item-row-gap: var(
      --trees-item-row-gap-override,
      calc(6px * var(--trees-density))
    );
    --trees-icon-width: var(--trees-icon-width-override, 16px);
    --trees-icon-nudge: var(
      --trees-icon-nudge-override,
      calc(1px * var(--trees-density))
    );
    --trees-row-height: var(--trees-item-height, 30px);
    --trees-git-lane-width: var(--trees-git-lane-width-override, 12px);
    --trees-action-lane-width: var(
      --trees-action-lane-width-override,
      calc(var(--trees-icon-width) + 2px)
    );
    /* Keep the floating trigger aligned with the row's action lane. Going in
       from the root's right edge: the scroll container reserves
       \`--trees-padding-inline\` of effective inset on each side (its asymmetric
       padding formula cancels the scrollbar gutter on the right), the row
       sits inside that inset, and its trailing \`--trees-item-padding-x\` is the
       action lane itself. The trigger's own focus-ring margin then trims one
       pixel back so the button's visible right edge lines up with the lane. */
    --trees-context-menu-trigger-inline-offset: calc(
      var(--trees-padding-inline) + var(--trees-item-padding-x) -
        var(--trees-focus-ring-width)
    );

    --trees-scrollbar-gutter: var(--trees-scrollbar-gutter-override, 6px);
    --trees-padding-inline: var(--trees-padding-inline-override, 16px);

    color-scheme: light dark;
    display: flex;
    flex-direction: column;
    font-size: var(--trees-font-size);
    color: var(--trees-fg);
    background-color: var(--trees-bg);
    --truncate-marker-background-color: var(--trees-bg);
    --truncate-marker-background-overlay-color: transparent;
    font-family: var(--trees-font-family);
    font-weight: var(--trees-font-weight-regular);
  }

  :host([data-file-tree-virtualized='true']) {
    height: 100%;
    overflow: hidden;
  }

  [data-file-tree-virtualized-wrapper='true'] {
    height: 100%;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  [data-file-tree-virtualized-root='true'] {
    height: 100%;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  [data-file-tree-virtualized-scroll='true'],
  [data-file-tree-scrollbar-measure='true'] {
    --trees-scrollbar-thumb-current: transparent;
    overflow-y: auto;
    scrollbar-gutter: stable;

    &:hover {
      --trees-scrollbar-thumb-current: var(--trees-scrollbar-thumb);
    }

    &::-webkit-scrollbar {
      width: var(--trees-scrollbar-gutter);
      height: var(--trees-scrollbar-gutter);
    }

    &::-webkit-scrollbar-track {
      background: transparent;
    }

    &::-webkit-scrollbar-thumb {
      background-color: var(--trees-scrollbar-thumb-current);
      border: 1px solid transparent;
      background-clip: content-box;
      border-radius: calc(var(--trees-scrollbar-gutter) / 2);
    }

    &::-webkit-scrollbar-corner {
      background-color: transparent;
    }
  }

  /* These are styles for a temporarily generated element to measure the size
   * of the scrollbar.  It's intended to be somewhat similar in scrollbar style
   * scope to the scrollable tree so \`--trees-scrollbar-gutter-measured\` is an
   * accurate reflection of the size the scrollbar gutter takes up. */
  [data-file-tree-scrollbar-measure='true'] {
    position: absolute;
    top: 0;
    left: 0;
    visibility: hidden;
    pointer-events: none;
    width: 100px;
    height: 100px;
  }

  @supports (-moz-appearance: none) {
    [data-file-tree-virtualized-scroll='true'],
    [data-file-tree-scrollbar-measure='true'] {
      scrollbar-width: thin;
      scrollbar-color: var(--trees-scrollbar-thumb-current) transparent;
    }
  }

  [data-file-tree-virtualized-scroll='true'] {
    position: relative;
    overflow-y: auto;
    flex: 1 1 0;
    min-height: 0;
    padding-inline: max(
        calc(var(--trees-padding-inline) - var(--trees-item-margin-x)),
        0px
      )
      /* NOTE(amadeus): We can assume that all Webkit based browser gutters
       * will align to the value of '--trees-scrollbar-gutter', however if not, then
       * \`--trees-scrollbar-gutter-measured\` should correct it. Mostly we are
       * hoping to avoid SSR alignment jumps if possible. In non-SSR'd environments
       * \`--trees-scrollbar-gutter-measured\` should always be immediately available.
       */
      max(
        calc(
          var(--trees-padding-inline) - var(--trees-item-margin-x) -
            var(
              --trees-scrollbar-gutter-measured,
              var(--trees-scrollbar-gutter)
            )
        ),
        0px
      );
  }

  @supports (-moz-appearance: none) {
    [data-file-tree-virtualized-scroll='true'] {
      padding-inline: max(
          calc(var(--trees-padding-inline) - var(--trees-item-margin-x)),
          0px
        )
        /* NOTE(amadeus): However on Firefox it can vary a little bit, but most
         * likely the majority of cases will default to a 0px width scrollbar lets
         * inherit that first to avoid SSR jumps. In non-SSR'd environments
         * \`--trees-scrollbar-gutter-measured\` should always be immediately available.
         */
        max(
          calc(
            var(--trees-padding-inline) - var(--trees-item-margin-x) -
              var(--trees-scrollbar-gutter-measured, 0px)
          ),
          0px
        );
    }
  }

  [data-file-tree-sticky-overlay='true'] {
    position: sticky;
    top: 0;
    height: 0;
    z-index: 4;
    overflow: visible;
    pointer-events: none;
  }

  /* The overlay DOM is kept populated even at scrollTop=0 so the browser has
   * the rendered rows on hand the moment scrolling begins — otherwise the
   * compositor paints a scrolled frame before React can mount the overlay,
   * and the topmost sticky folder jumps up by a couple of pixels before it
   * "snaps" into its pinned position. We hide it via CSS whenever the scroll
   * is at the top and no scroll is in progress, so the preview doesn't leak
   * through at rest. \`data-overlay-reveal\` is stamped on the root only when
   * the user initiates a scroll while already at the top — exactly the case
   * where we need the pre-mounted overlay to be visible through the first
   * compositor frame. It is deliberately distinct from the general
   * \`data-is-scrolling\` flag so a scroll that ends at the top (e.g. ArrowUp
   * navigation) re-hides the overlay the instant the scroll lands, rather
   * than waiting for the hover-suppression timer to elapse. */
  [data-file-tree-virtualized-root='true'][data-scroll-at-top='true']:not(
      [data-overlay-reveal]
    )
    [data-file-tree-sticky-overlay='true'] {
    visibility: hidden;
  }

  [data-file-tree-sticky-overlay-content='true'] {
    background-color: var(--trees-bg);
    position: relative;
    pointer-events: none;
  }

  [data-file-tree-virtualized-list='true'] {
    background-color: var(--trees-bg);
    position: relative;
    min-height: 100%;
    width: 100%;
    overflow-anchor: none;

    &[data-is-scrolling] {
      pointer-events: none;
    }
  }

  [data-file-tree-virtualized-sticky-offset='true'] {
    contain: layout size;
  }

  [data-file-tree-virtualized-sticky='true'] {
    position: sticky;
    top: 0;
    width: 100%;
    display: flex;
    flex-direction: column;
    isolation: isolate;
    /* Promote to its own compositor layer so text inside the window is
     * rasterized once and GPU-translated during scroll. Without this, the
     * browser re-paints the window (and its text) at every scroll frame,
     * which produces visible 1px shake / character tearing. */
    will-change: transform;
  }

  [data-file-tree-search-container] {
    display: flex;
    padding: 0;
    padding-inline: var(--trees-padding-inline);
    margin-bottom: var(--trees-item-row-gap);
  }

  [data-file-tree-search-input] {
    --trees-focus-ring-width: 2px;
    font-family: var(--trees-font-family);
    font-size: var(--trees-font-size);
    flex: 1;
    height: var(--trees-row-height);
    /* 1px breathing room so the focus-visible outline isn't clipped when the
     * input sits flush against the top of the scroll container. */
    margin-block: 1px;
    padding-inline: var(--trees-item-padding-x);
    line-height: var(--trees-row-height);
    color: var(--trees-search-fg);
    background-color: var(--trees-search-bg);
    border: 1px solid var(--trees-border-color);
    border-radius: var(--trees-border-radius);
    outline: none;

    &::placeholder {
      color: color-mix(
        in lab,
        var(--trees-search-fg) 65%,
        var(--trees-search-bg)
      );
    }

    &:focus-visible,
    &[data-file-tree-search-input-fake-focus='true'] {
      outline: var(--trees-focus-ring-width) solid var(--trees-focus-ring-color);
      outline-offset: var(--trees-focus-ring-offset);
    }
  }

  /* The wrapper for the tree items */
  [role='tree'] {
    position: relative;
    display: flex;
    flex-direction: column;
    gap: var(--trees-gap-override, 0);
  }

  /* LIST ITEM */
  [data-type='item'] {
    color: inherit;
    font-family: var(--trees-font-family);
    font-size: var(--trees-font-size);
    text-align: start;
    outline: none;
    background-color: var(--trees-bg);
    border: none;
    position: relative;

    padding: 0 var(--trees-item-padding-x);
    margin: 0 var(--trees-item-margin-x);
    cursor: pointer;
    -webkit-user-select: none;
            user-select: none;
    -webkit-touch-callout: none;
    touch-action: manipulation;
    display: flex;
    flex: 0 0 var(--trees-row-height);
    align-items: center;
    height: var(--trees-row-height);
    line-height: var(--trees-row-height);
    gap: var(--trees-item-row-gap);
    border-radius: var(--trees-border-radius);
    /* Row states may be translucent, so markers paint the tree background first
     * and then the state color on top to avoid compositing the same alpha twice. */
    --truncate-marker-background-color: var(--trees-bg);
    --truncate-marker-background-overlay-color: transparent;
    --truncate-marker-block-inset: 0px;

    &:hover,
    &[data-item-context-hover='true'] {
      background-color: var(--trees-bg-muted);
      --truncate-marker-background-overlay-color: var(--trees-bg-muted);
    }

    &[data-item-focused='true'],
    &:focus-visible {
      z-index: 2;

      /* Flattened segment markers sit high enough to cover the row outline unless
       * their painted background is inset by the focus ring width. */
      [data-item-flattened-subitems] {
        --truncate-marker-block-inset: var(--trees-focus-ring-width);
      }

      &::before {
        position: absolute;
        inset: 0;
        content: '';
        display: block;
        border-radius: var(--trees-border-radius);
        outline: var(--trees-focus-ring-width) solid
          var(--trees-focus-ring-color);
        outline-offset: var(--trees-focus-ring-offset);
        pointer-events: none;
      }

      &[data-item-selected='true']::before {
        outline-color: var(--trees-selected-focused-border-color);
      }
    }

    &[data-item-selected='true'] {
      color: var(--trees-selected-fg);
      background-color: var(--trees-selected-bg);
      --truncate-marker-background-overlay-color: var(--trees-selected-bg);
      z-index: 3;

      [data-item-section='icon'] {
        color: var(--trees-selected-fg);
      }
    }

    &[data-item-search-match='true'] {
      font-weight: var(--trees-search-font-weight);
    }
  }

  [data-type='item'][data-file-tree-sticky-row='true'] {
    pointer-events: auto;
  }

  /* Sticky rows opt back into pointer events because the overlay wrapper is
   * inert. During scroll, put them back under the same hover suppression as
   * the virtualized list so translucent hover states and menu triggers do not
   * paint over rows moving beneath the sticky stack. */
  [data-file-tree-virtualized-root='true'][data-is-scrolling]
    [data-type='item'][data-file-tree-sticky-row='true'] {
    pointer-events: none;
  }

  [data-file-tree-virtualized-root='true'][data-is-scrolling]
    [data-type='item'][data-file-tree-sticky-row='true']:hover:not(
      [data-item-selected='true']
    ),
  [data-file-tree-virtualized-root='true'][data-is-scrolling]
    [data-type='item'][data-file-tree-sticky-row='true'][data-item-context-hover='true']:not(
      [data-item-selected='true']
    ) {
    background-color: var(--trees-bg);
    --truncate-marker-background-overlay-color: transparent;
  }

  [data-item-selected='true']:has(+ [data-item-selected='true']) {
    border-bottom-left-radius: 0;
    border-bottom-right-radius: 0;
  }

  [data-item-selected='true'] + [data-item-selected='true'] {
    border-top-left-radius: 0;
    border-top-right-radius: 0;
  }

  /* Flattened Directory Parts */
  [data-item-flattened-subitems] {
    display: inline-flex;
    align-items: center;
    gap: 2px;
  }
  [data-item-flattened-subitem]:hover,
  [data-item-flattened-subitem-drag-target='true'] {
    text-decoration: underline;
  }

  /* Icon for each item */
  [data-item-section='icon'] {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--trees-fg-muted);
    fill: currentColor;
    width: var(--trees-icon-width);
  }

  :where([data-item-section='icon'] > [data-icon-token]) {
    color: var(--trees-fg-muted);
  }

  [data-file-tree-colored-icons='true'] {
    [data-icon-token='astro'] {
      color: var(--trees-file-icon-color-astro);
    }
    [data-icon-token='babel'] {
      color: var(--trees-file-icon-color-babel);
    }
    [data-icon-token='bash'] {
      color: var(--trees-file-icon-color-bash);
    }
    [data-icon-token='biome'] {
      color: var(--trees-file-icon-color-biome);
    }
    [data-icon-token='bootstrap'] {
      color: var(--trees-file-icon-color-bootstrap);
    }
    [data-icon-token='browserslist'] {
      color: var(--trees-file-icon-color-browserslist);
    }
    [data-icon-token='bun'] {
      color: var(--trees-file-icon-color-bun);
    }
    [data-icon-token='c'] {
      color: var(--trees-file-icon-color-c);
    }
    [data-icon-token='cpp'] {
      color: var(--trees-file-icon-color-cpp);
    }
    [data-icon-token='claude'] {
      color: var(--trees-file-icon-color-claude);
    }
    [data-icon-token='css'] {
      color: var(--trees-file-icon-color-css);
    }
    [data-icon-token='database'] {
      color: var(--trees-file-icon-color-database);
    }
    [data-icon-token='default'] {
      color: var(--trees-file-icon-color-default);
    }
    [data-icon-token='docker'] {
      color: var(--trees-file-icon-color-docker);
    }
    [data-icon-token='eslint'] {
      color: var(--trees-file-icon-color-eslint);
    }
    [data-icon-token='git'] {
      color: var(--trees-file-icon-color-git);
    }
    [data-icon-token='go'] {
      color: var(--trees-file-icon-color-go);
    }
    [data-icon-token='graphql'] {
      color: var(--trees-file-icon-color-graphql);
    }
    [data-icon-token='html'] {
      color: var(--trees-file-icon-color-html);
    }
    [data-icon-token='image'] {
      color: var(--trees-file-icon-color-image);
    }
    [data-icon-token='javascript'] {
      color: var(--trees-file-icon-color-javascript);
    }
    [data-icon-token='json'] {
      color: var(--trees-file-icon-color-json);
    }
    [data-icon-token='markdown'] {
      color: var(--trees-file-icon-color-markdown);
    }
    [data-icon-token='mcp'] {
      color: var(--trees-file-icon-color-mcp);
    }
    [data-icon-token='npm'] {
      color: var(--trees-file-icon-color-npm);
    }
    [data-icon-token='oxc'] {
      color: var(--trees-file-icon-color-oxc);
    }
    [data-icon-token='postcss'] {
      color: var(--trees-file-icon-color-postcss);
    }
    [data-icon-token='prettier'] {
      color: var(--trees-file-icon-color-prettier);
    }
    [data-icon-token='python'] {
      color: var(--trees-file-icon-color-python);
    }
    [data-icon-token='react'] {
      color: var(--trees-file-icon-color-react);
    }
    [data-icon-token='ruby'] {
      color: var(--trees-file-icon-color-ruby);
    }
    [data-icon-token='rust'] {
      color: var(--trees-file-icon-color-rust);
    }
    [data-icon-token='sass'] {
      color: var(--trees-file-icon-color-sass);
    }
    [data-icon-token='svg'] {
      color: var(--trees-file-icon-color-svg);
    }
    [data-icon-token='svelte'] {
      color: var(--trees-file-icon-color-svelte);
    }
    [data-icon-token='svgo'] {
      color: var(--trees-file-icon-color-svgo);
    }
    [data-icon-token='swift'] {
      color: var(--trees-file-icon-color-swift);
    }
    [data-icon-token='table'] {
      color: var(--trees-file-icon-color-table);
    }
    [data-icon-token='text'] {
      color: var(--trees-file-icon-color-text);
    }
    [data-icon-token='tailwind'] {
      color: var(--trees-file-icon-color-tailwind);
    }
    [data-icon-token='terraform'] {
      color: var(--trees-file-icon-color-terraform);
    }
    [data-icon-token='typescript'] {
      color: var(--trees-file-icon-color-typescript);
    }
    [data-icon-token='vite'] {
      color: var(--trees-file-icon-color-vite);
    }
    [data-icon-token='vscode'] {
      color: var(--trees-file-icon-color-vscode);
    }
    [data-icon-token='vue'] {
      color: var(--trees-file-icon-color-vue);
    }
    [data-icon-token='wasm'] {
      color: var(--trees-file-icon-color-wasm);
    }
    [data-icon-token='webpack'] {
      color: var(--trees-file-icon-color-webpack);
    }
    [data-icon-token='yml'] {
      color: var(--trees-file-icon-color-yml);
    }
    [data-icon-token='zig'] {
      color: var(--trees-file-icon-color-zig);
    }
    [data-icon-token='zip'] {
      color: var(--trees-file-icon-color-zip);
    }
  }

  /* Chevron rotation and visual alignment */
  /* Chevron pointing down */
  [data-icon-name='file-tree-icon-chevron'] {
    &[data-align-capitals='false'] {
      transform: translate(0, var(--trees-icon-nudge));
    }
    &[data-align-capitals='true'] {
      transform: translate(0, 0);
    }
  }

  [data-item-section='content'] {
    flex: 0 1 auto;
    text-align: start;
    min-width: 0;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    /* Breaks middle truncate component to also set this */
    /* white-space: nowrap; */
  }

  [data-item-section='decoration'] {
    flex: 1 1 0;
    min-width: 0;
    display: flex;
    justify-content: flex-end;
    text-align: end;
    overflow: hidden;
    color: var(--trees-fg-muted);
  }

  [data-item-section='decoration'] > span {
    min-width: 0;
    max-width: 100%;
    display: inline-flex;
    align-items: center;
    justify-content: flex-end;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  [data-item-section='git'],
  [data-item-section='action'] {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  [data-item-section='git'] {
    width: var(--trees-git-lane-width);
  }

  [data-item-section='action'] {
    width: var(--trees-action-lane-width);
    color: var(--trees-fg-muted);
    fill: currentColor;
    pointer-events: none;
  }

  [data-item-section='git'] > span,
  [data-item-section='action'] > span {
    width: 100%;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }

  [data-item-action-affordance='decorative'] {
    opacity: 0.85;
  }

  [data-item-rename-input] {
    appearance: none;
    width: 100%;
    min-width: 0;
    height: calc(var(--trees-row-height) - 4px);
    font-family: inherit;
    font-size: inherit;
    /* line-height: calc(var(--trees-row-height) - 8px); */
    color: inherit;
    background-color: transparent;
    border: 0;
    padding-inline: 6px;
    outline: none;
    box-sizing: border-box;
  }

  [data-item-section='content']:has([data-item-rename-input])
    ~ [data-item-section='action'],
  [data-item-section='content']:has([data-item-rename-input])
    ~ [data-item-section='decoration'] {
    display: none;
  }

  /* Chevron pointing right */
  [aria-expanded='false'][data-item-type='folder']
    > [data-item-section='icon']
    > [data-icon-name='file-tree-icon-chevron'] {
    &[data-align-capitals='true'] {
      transform: rotate(-90deg)
        translate(
          calc(var(--trees-icon-nudge) / 2),
          calc(var(--trees-icon-nudge) / 2)
        );
    }
    &[data-align-capitals='false'] {
      transform: rotate(-90deg)
        translate(
          calc(var(--trees-icon-nudge) / 2 * -1),
          calc(var(--trees-icon-nudge) / 2)
        );
    }
  }

  /* LIST IDENTATION */
  /* Spacing container */
  [data-item-section='spacing'] {
    display: flex;
    flex-direction: row;
    align-items: center;
    justify-content: center;
    height: var(--trees-row-height);
    padding-left: calc(calc(var(--trees-icon-width) / 2) - 0.5px);

    &:empty {
      padding-left: 0;
    }
  }

  /* Spacing per level */
  [data-item-section='spacing-item'] {
    transform: translateX(-0.25px);
    display: inline-block;
    border-left: 1px solid var(--trees-indent-guide-bg);
    height: 100%;
    margin-right: calc(var(--trees-level-gap) - 1px);
    opacity: 0;
    transition: opacity 150ms ease;

    & + & {
      margin-left: calc(
        var(--trees-item-row-gap) + calc(var(--trees-icon-width) / 2) - 0.5px
      );
    }
  }

  :host(:hover) [data-item-section='spacing-item'] {
    opacity: 0.75;
  }

  /* Git status indicator */

  /* This is a folder that contains a git change */
  [data-item-contains-git-change='true'] > [data-item-section='git'] {
    color: var(--trees-git-modified-color);
    opacity: 0.5;
    fill: currentColor;
  }

  /* These are files that have a git change */
  [data-item-git-status] {
    &
      > :where([data-item-section='icon'])
      > :where(:not([data-icon-name='file-tree-icon-chevron'])) {
      color: var(--trees-item-git-status-color);
    }
    & > [data-item-section='content'] {
      color: var(--trees-item-git-status-color);
    }
    & > [data-item-section='git'] {
      color: var(--trees-item-git-status-color);
      font-weight: var(--trees-font-weight-semibold);
    }
  }

  [data-item-git-status='added'] {
    --trees-item-git-status-color: var(--trees-git-added-color);
  }

  [data-item-git-status='deleted'] {
    --trees-item-git-status-color: var(--trees-git-deleted-color);
  }

  [data-item-git-status='ignored'] {
    --trees-item-git-status-color: var(--trees-git-ignored-color);

    & > [data-item-section='icon'] {
      opacity: 0.5;
    }
  }

  [data-item-section='git'] [data-icon-name='file-tree-icon-dot'] {
    /* this is a nudge to align the dot with the likely lowercase text. it's slightly
    generalizable, but other fonts are gonna need other nudges i assume */
    transform: translateY(calc(0.65ex - 50%));
  }

  [data-item-git-status='modified'] {
    --trees-item-git-status-color: var(--trees-git-modified-color);
  }

  [data-item-git-status='renamed'] {
    --trees-item-git-status-color: var(--trees-git-renamed-color);
  }

  [data-item-git-status='untracked'] {
    --trees-item-git-status-color: var(--trees-git-untracked-color);
  }

  /* Drag and drop */
  [data-item-drag-target='true'] {
    background-color: var(--trees-selected-bg);
  }

  [data-item-dragging='true'] {
    opacity: 0.5;
  }

  /* Lock icon for locked paths (sibling of content) */
  [data-item-section='lock'] {
    flex: 0 0 auto;
    margin-left: auto;
    display: flex;
    align-items: center;
    color: var(--trees-fg-muted);
  }
  [data-item-section='lock'] svg {
    display: block;
  }

  [data-type='header-slot'] {
    display: block;
    flex: 0 0 auto;
  }

  [data-type='context-menu-wash'] {
    position: absolute;
    inset: 0;
    z-index: 3;
    background-color: transparent;
    touch-action: none;
  }

  [data-type='context-menu-anchor'] {
    position: absolute;
    top: 0;
    right: var(--trees-context-menu-trigger-inline-offset);
    z-index: 4;
    display: none;
    align-items: center;

    &[data-visible='true'] {
      display: flex;
    }
  }

  /* Hide the floating trigger while the scroll container is actively moving.
   * The anchor is positioned against the root, not the scroll content, so its
   * \`top\` follows the row via a React state update — one frame behind the
   * compositor. That delay is visible as the trigger hovering over the wrong
   * row during the first frame of a scroll. The \`data-is-scrolling\` flag on
   * the root is flipped synchronously on \`wheel\`/\`touchmove\`/\`keydown\` before
   * the compositor commits the next paint, so this selector hides the anchor
   * in the same frame the scroll begins. */
  [data-file-tree-virtualized-root='true'][data-is-scrolling]
    [data-type='context-menu-anchor'] {
    display: none;
  }

  [data-type='context-menu-anchor'] > slot[name='context-menu'] {
    display: block;
    width: 0;
    min-width: 0;
    flex: 0 0 0;
    overflow: visible;
  }

  /* Single floating context menu trigger */
  [data-type='context-menu-trigger'] {
    all: unset;
    align-items: center;
    justify-content: center;
    width: var(--trees-action-lane-width);
    color: var(--trees-fg-muted);
    fill: currentColor;
    cursor: pointer;
    font-family: var(--trees-font-family);
    font-size: var(--trees-font-size);
    border-top-right-radius: var(--trees-border-radius);
    border-bottom-right-radius: var(--trees-border-radius);
    margin: var(--trees-focus-ring-width);
    height: calc(var(--trees-row-height) - var(--trees-focus-ring-width) * 2);
    border-width: 0;
    transition: color 120ms ease;

    display: flex;
  }

  [data-type='context-menu-trigger']:hover,
  [data-type='context-menu-trigger'][aria-expanded='true'] {
    color: var(--trees-fg);
  }

  /** @pierre/truncate css here, manually copy pasted for now */
  [data-truncate-container] {
    /* CUSTOM TO TREES, TO SUPPORT THE OUTLINE */
    margin-top: -1px;
    margin-bottom: -1px;

    /* Width of the fade from default marker to text */
    --truncate-internal-marker-fade-width: var(
      --truncate-marker-fade-width,
      2px
    );
    /* Width of the solid color between the fade from the default marker to the text */
    --truncate-internal-marker-gap: var(--truncate-marker-gap, 0px);
    /* Opacity of the marker 'color' property, not of the element itself */
    --truncate-internal-marker-opacity: var(--truncate-marker-opacity, 50%);
    /* Opacity of the marker 'color' property specifically for the middle truncate, not opacity of the element itself */
    --truncate-internal-middle-marker-opacity: var(
      --truncate-middle-marker-opacity,
      80%
    );
    /* Background color of the default marker */
    --truncate-internal-marker-background-color: var(
      --truncate-marker-background-color,
      light-dark(white, black)
    );
    --truncate-internal-marker-background-overlay-color: var(
      --truncate-marker-background-overlay-color,
      transparent
    );
    --truncate-internal-marker-block-inset: var(
      --truncate-marker-block-inset,
      0px
    );
    /* Duration of the fade out animation for the marker */
    --truncate-internal-marker-fade-out-duration: var(
      --truncate-marker-fade-out-duration,
      0ms
    );
    /* Duration of the fade in animation for the marker */
    --truncate-internal-marker-fade-in-duration: var(
      --truncate-marker-fade-in-duration,
      100ms
    );

    /* FADE Variant specifics */
    --truncate-internal-fade-marker-color: var(
      --truncate-fade-marker-color,
      #000
    );
    --truncate-internal-fade-marker-width: var(
      --truncate-fade-marker-width,
      0.2lh
    );

    /*
    In some special cases people might be adding spacing in other ways
    that would benefit from being able to override this, however the container
    query below can't use this and would need to be redeclared with the overridden
    value. It's a bad time, but better than nothing.
    */
    --truncate-internal-single-line-height: 1lh;

    height: var(--truncate-internal-single-line-height);
    min-width: 0;
    overflow: hidden;
  }

  [data-truncate-marker] {
    display: flex;
    position: absolute;
    height: var(--truncate-internal-single-line-height);
    padding-block: var(--truncate-internal-marker-block-inset);
    box-sizing: border-box;
    align-items: center;
    background-clip: content-box;
    z-index: 2;
    color: color-mix(
      in srgb,
      currentColor var(--truncate-internal-marker-opacity),
      transparent
    );

    /* Core trick for hiding the marker until overflow occurs */
    opacity: 0;
    transition: opacity var(--truncate-internal-marker-fade-out-duration)
      ease-in-out;
  }

  @container measure (height > 1lh) {
    [data-truncate-marker] {
      opacity: 1;
      transition: opacity var(--truncate-internal-marker-fade-in-duration)
        ease-in-out;
    }
  }

  [data-truncate-grid] {
    display: grid;
    position: relative;
  }

  [data-truncate-content='visible'] {
    white-space: nowrap;
  }

  [data-truncate-content='overflow'] {
    opacity: 0;
    pointer-events: none;
    -webkit-user-select: none;
            user-select: none;
    word-break: break-all;
    margin-top: calc(-1 * var(--truncate-internal-single-line-height));
  }

  [data-truncate-marker-cell] {
    container: measure / size;
    overflow: visible;
    -webkit-user-select: none;
            user-select: none;
    pointer-events: none;
  }

  [data-truncate-container='truncate'] {
    & [data-truncate-grid] {
      grid-template-columns: minmax(0, max-content) 0;
    }
    & [data-truncate-marker] {
      right: 0;
    }
    & [data-truncate-fade] {
      margin-right: calc(-2 * var(--truncate-internal-fade-marker-width));
    }
  }

  [data-truncate-container='fruncate'] {
    & [data-truncate-grid] {
      grid-template-columns: 0 minmax(0, max-content) auto;
    }
    & [data-truncate-content] {
      direction: rtl;
    }
    & [data-truncate-content] > span {
      unicode-bidi: plaintext;
    }
    & [data-truncate-fade] {
      margin-left: calc(-2 * var(--truncate-internal-fade-marker-width));
    }
  }

  [data-truncate-variant='default'] {
    & [data-truncate-marker] {
      background-color: var(--truncate-internal-marker-background-color);
      background-image: linear-gradient(
        var(--truncate-internal-marker-background-overlay-color),
        var(--truncate-internal-marker-background-overlay-color)
      );
    }
    & [data-truncate-marker]::after,
    & [data-truncate-marker]::before {
      content: '';
      position: absolute;
      width: calc(
        var(--truncate-internal-marker-fade-width) +
          var(--truncate-internal-marker-gap)
      );
      inset-block-start: var(--truncate-internal-marker-block-inset);
      height: max(
        0px,
        calc(
          var(--truncate-internal-single-line-height) -
            var(--truncate-internal-marker-block-inset) * 2
        )
      );
      background-color: var(--truncate-internal-marker-background-color);
      background-image: linear-gradient(
        var(--truncate-internal-marker-background-overlay-color),
        var(--truncate-internal-marker-background-overlay-color)
      );
      mask-image: linear-gradient(
        var(--truncate-internal-fade-dir),
        #000 0%,
        #000 var(--truncate-internal-marker-gap),
        transparent 100%
      );
    }
    & [data-truncate-marker]::after {
      --truncate-internal-fade-dir: to right;
      right: calc(
        -1 *
          (
            var(--truncate-internal-marker-fade-width) +
              var(--truncate-internal-marker-gap)
          )
      );
    }
    & [data-truncate-marker]::before {
      --truncate-internal-fade-dir: to left;
      left: calc(
        -1 *
          (
            var(--truncate-internal-marker-fade-width) +
              var(--truncate-internal-marker-gap)
          )
      );
    }
  }

  [data-truncate-variant='fade'] {
    & [data-truncate-marker] {
      background: transparent;
    }
  }

  [data-truncate-fade] {
    box-shadow:
      0 0 calc(var(--truncate-internal-fade-marker-width) / 2)
        var(--truncate-internal-fade-marker-color),
      0 0 var(--truncate-internal-fade-marker-width)
        var(--truncate-internal-fade-marker-color);
    width: calc(var(--truncate-internal-fade-marker-width) * 2);
    height: calc(
      var(--truncate-internal-single-line-height) -
        (var(--truncate-internal-fade-marker-width) * 2)
    );
    margin: var(--truncate-internal-fade-marker-width) 0;
  }

  [data-truncate-group-container='middle'] {
    & [data-truncate-container] {
      --truncate-marker-opacity: var(--truncate-internal-middle-marker-opacity);
    }

    display: flex;
    min-width: 0;

    & > div {
      min-width: 0;
    }

    & > div[data-truncate-segment-priority='1'] {
      flex: 0 1 max-content;
    }
    & > div[data-truncate-segment-priority='2'] {
      flex: 0 999999 max-content;
    }
  }
}
`;function J4(J){return`@layer base, unsafe;
@layer base {
  ${J}
}`}function S7(J){return`@layer base, unsafe;
@layer unsafe {
  ${J}
}`}var f7=new WeakMap;function $Q(J){let Q=f7.get(J);if(Q!=null)return Q;let X=document.createElement("div");X.setAttribute(w7,"true");let Z=document.createElement("div");Z.style.position="relative",Z.style.height="200%",X.appendChild(Z),J.appendChild(X);let Y=Math.max(X.offsetWidth-X.clientWidth,0);return X.remove(),f7.set(J,Y),Y}function P7(J,Q){if(!J.isConnected)return;let X=$Q(Q);if(X==null)return;let Z=Q.querySelector(`style[${l4}]`),Y=Z instanceof HTMLStyleElement?Z:document.createElement("style");if(!(Z instanceof HTMLStyleElement))Y.setAttribute(l4,""),Q.appendChild(Y);Y.textContent=`:host { ${N7}: ${X}px; }`}var Q4;function UQ(J){if(typeof CSSStyleSheet<"u"&&typeof CSSStyleSheet.prototype.replaceSync==="function"&&"adoptedStyleSheets"in J){if(Q4==null)Q4=new CSSStyleSheet,Q4.replaceSync(J4(i4));let Q=!1;try{J.adoptedStyleSheets=[Q4],Q=!0}catch{}if(Q){J.querySelector(`style[${F3}]`)?.remove();return}}if(J.querySelector(`style[${F3}]`)==null){let Q=document.createElement("style");Q.setAttribute(F3,""),Q.textContent=J4(i4),J.prepend(Q)}}function X4(J,Q){zQ(J,Q),UQ(Q),P7(J,Q)}function zQ(J,Q){let X=J.querySelector('template[shadowrootmode="open"], template[data-file-tree-shadowrootmode="open"]');if(!(X instanceof HTMLTemplateElement))return;if(Q.childNodes.length>0)return;if(Q.appendChild(X.content.cloneNode(!0)),X.hasAttribute("shadowrootmode"))X.remove()}if(typeof HTMLElement<"u"&&customElements.get(I1)==null){class J extends HTMLElement{constructor(){super()}connectedCallback(){let Q=this.shadowRoot??this.attachShadow({mode:"open"});X4(this,Q)}}if(customElements.define(I1,J),typeof document<"u")for(let Q of Array.from(document.querySelectorAll(I1))){if(!(Q instanceof HTMLElement))continue;X4(Q,Q.shadowRoot??Q.attachShadow({mode:"open"}))}}var x7=!0;var g7=(J)=>J.startsWith(d4)?J.slice(d4.length):J;function KQ(J){let Q=J.lastIndexOf("/");if(Q<0)return{parentPath:"",baseName:J};return{parentPath:J.slice(0,Q),baseName:J.slice(Q+1)}}function AQ(J,Q){return J===""?Q:`${J}/${Q}`}function m7({files:J,path:Q,isFolder:X,nextBasename:Z}){let Y=g7(Q),W=Z.trim();if(W.length===0)return{error:"Name cannot be empty."};if(W.includes("/"))return{error:'Name cannot include "/".'};let{parentPath:q,baseName:G}=KQ(Y);if(W===G)return{nextFiles:J,sourcePath:Y,destinationPath:Y,isFolder:X};let $=AQ(q,W),A=Array(J.length),K=new Set;if(!X){let _=`${$}/`,F=!1;for(let k=0;k<J.length;k++){let b=J[k];if(b!==Y&&b.startsWith(_))return{error:`"${$}" already exists.`};let E=b===Y?$:b;if(K.has(E))return{error:`"${$}" already exists.`};if(K.add(E),A[k]=E,b===Y)F=!0}if(!F)return{error:"Could not find the selected file to rename."};return{nextFiles:A,sourcePath:Y,destinationPath:$,isFolder:X}}let M=`${Y}/`,U=`${$}/`,j=0;for(let _=0;_<J.length;_++){let F=J[_],k=F===Y||F.startsWith(M);if(!k&&(F===$||F.startsWith(U)))return{error:`"${$}" already exists.`};let b=k?`${$}${F.slice(Y.length)}`:F;if(K.has(b))return{error:`"${$}" already exists.`};if(K.add(b),A[_]=b,k)j++}if(j===0)return{error:"Could not find the selected folder to rename."};return{nextFiles:A,sourcePath:Y,destinationPath:$,isFolder:X}}function MQ(J){return J.endsWith("/")}function _Q(J){let Q=J.endsWith("/")?J.slice(0,-1):J,X=Q.lastIndexOf("/"),Z=X<0?Q:Q.slice(X+1);return J.endsWith("/")?`${Z}/`:Z}function jQ(J){let Q=[],X=new Set;for(let Y of J){if(X.has(Y))continue;X.add(Y),Q.push(Y)}let Z=new Set;for(let Y of Q.toSorted((W,q)=>{if(W.length!==q.length)return W.length-q.length;return W.localeCompare(q)})){let W=(Y.endsWith("/")?Y.slice(0,-1):Y).split("/"),q=!1;for(let G=0;G<W.length-1;G+=1){let $=`${W.slice(0,G+1).join("/")}/`;if(!Z.has($))continue;q=!0;break}if(q)continue;Z.add(Y)}return Q.filter((Y)=>Z.has(Y))}function I7(J,Q){return Q.includes(J)?jQ(Q):[J]}function u7(J,Q){if(J===Q)return!0;if(J==null||Q==null)return!1;return J.kind===Q.kind&&J.directoryPath===Q.directoryPath&&J.flattenedSegmentPath===Q.flattenedSegmentPath&&J.hoveredPath===Q.hoveredPath}function s4(J,Q){return{draggedPaths:J,target:Q}}function o4(J,Q){if(Q.kind!=="directory"||Q.directoryPath==null)return!1;for(let X of J){if(!MQ(X))continue;if(Q.directoryPath===X||Q.directoryPath.startsWith(X))return!0}return!1}function OQ(J,Q){if(Q.kind==="root"||Q.directoryPath==null)return _Q(J);return Q.directoryPath}function c7(J,Q){let X=J.map((Z)=>{let Y=OQ(Z,Q);if(Y===Z)return null;return{from:Z,to:Y,type:"move"}}).filter((Z)=>{return Z!=null});if(X.length===0)return null;return{operations:X,result:{draggedPaths:J,operation:X.length===1?"move":"batch",target:Q}}}function LQ(J,Q){if(J===Q)return!0;if(J.length!==Q.length)return!1;for(let X=0;X<J.length;X+=1)if(J[X]!==Q[X])return!1;return!0}function r4(J,Q,X){let{paths:Z,preparedInput:Y}=J;if(Y==null){if(Z==null)throw Error("FileTree requires paths or preparedInput");return{paths:Z,preparedInput:void 0}}let W=Y.paths;if(Z==null)return{paths:W,preparedInput:Y};if(!LQ(m1.preparePaths(Z,X==null?{}:{sort:X}),W))throw Error(`FileTree ${Q} received paths and preparedInput for different path lists`);return{paths:W,preparedInput:Y}}function a4(J){return J.operation==="add"||J.operation==="remove"||J.operation==="move"||J.operation==="batch"}function BQ(J,Q,X){if(J===Q)return X;let Z=Q.endsWith("/")?Q:`${Q}/`;if(!J.startsWith(Z))return J;return`${X.endsWith("/")?X:`${X}/`}${J.slice(Z.length)}`}function FQ(J,Q){if(J===Q)return!0;let X=Q.endsWith("/")?Q:`${Q}/`;return J.startsWith(X)}function p1(J,Q,X=!1){if(J==null)return null;switch(Q.operation){case"add":case"expand":case"collapse":case"mark-directory-unloaded":case"begin-child-load":case"apply-child-patch":case"complete-child-load":case"fail-child-load":case"cleanup":return J;case"remove":return FQ(J,Q.path)?X?J:null:J;case"move":return BQ(J,Q.from,Q.to);case"batch":{let Z=J;for(let Y of Q.events)if(Z=p1(Z,Y,X),Z==null)return null;return Z}}}function Z4(J){return{canonicalChanged:J.canonicalChanged,projectionChanged:J.projectionChanged,visibleCountDelta:J.visibleCountDelta}}function p7(J){switch(J.operation){case"add":return{...Z4(J),operation:"add",path:J.path};case"remove":return{...Z4(J),operation:"remove",path:J.path,recursive:J.recursive};case"move":return{...Z4(J),from:J.from,operation:"move",to:J.to}}}function HQ(J){return{...Z4(J),events:J.events.filter((Q)=>Q.operation==="add"||Q.operation==="remove"||Q.operation==="move").map((Q)=>p7(Q)),operation:"batch"}}function h7(J){switch(J.operation){case"add":case"remove":case"move":return p7(J);case"batch":return HQ(J);default:return null}}function Y4(J,Q){if(J.size!==Q.length)return!1;for(let X of Q)if(!J.has(X))return!1;return!0}function t0(J){let Q=J.endsWith("/")?J.slice(0,-1):J;if(Q.length===0)return[];let X=Q.split("/");return X.slice(0,-1).map((Z,Y)=>`${X.slice(0,Y+1).join("/")}/`)}function W4(J){return t0(J).at(-1)??null}function n4(J,Q){if(Q==null)return J;return J.startsWith(Q)?J.slice(Q.length):J}function k3(J){return J.endsWith("/")}var t4=(J)=>J.toLowerCase();function l7(J){let Q=J.endsWith("/")?J.slice(0,-1):J,X=Q.lastIndexOf("/");return X<0?Q:Q.slice(X+1)}function e4(J){return J.endsWith("/")?J.slice(0,-1):J}function J5(J,Q){return Q&&!J.endsWith("/")?`${J}/`:J}var d7=(J)=>{let Q=J.trim();if(Q.length===0)return"";return(Q.includes("\\")?Q.replaceAll("\\","/"):Q).toLowerCase()};var Q5=Symbol("FILE_TREE_RENAME_VIEW"),kQ=512,VQ=512;function RQ(J){return J==="top"||J==="center"?J:"nearest"}function EQ(J,Q,X){if(J===0)return-1;if(X!=null){let Z=Q(X);if(Z!=null)return Z;let Y=t0(X);for(let W=Y.length-1;W>=0;W-=1){let q=Y[W];if(q==null)continue;let G=Q(q);if(G!=null)return G}}return 0}function DQ(J,Q,X){if(J.paths.length===0)return{focusedIndex:-1,getParentIndex:J.getParentIndex,paths:J.paths,posInSetByIndex:J.posInSetByIndex,setSizeByIndex:J.setSizeByIndex};if(Q==null)return{focusedIndex:0,getParentIndex:J.getParentIndex,paths:J.paths,posInSetByIndex:J.posInSetByIndex,setSizeByIndex:J.setSizeByIndex};let Z=X??((Y)=>J.visibleIndexByPath.get(Y)??null);return{focusedIndex:EQ(J.paths.length,Z,Q),getParentIndex:J.getParentIndex,paths:J.paths,posInSetByIndex:J.posInSetByIndex,setSizeByIndex:J.setSizeByIndex}}var i7=class{#J;#X=new Set;#U=new Map;#z=null;#q=null;#I=new Map;#u=new Map;#O=-1;#Z=null;#L=!1;#b=(J)=>-1;#B=new Map;#_=null;#F=null;#H=null;#k=null;#A=null;#c;#p;#f;#Y=[];#h=new Int32Array(0);#l=new Int32Array(0);#t=void 0;#y=!1;#G=null;#j="";#w=!1;#D=new Set;#d=[];#i;#s=null;#$=null;#P=null;#v=null;#E=null;#x=null;#e=null;#D0=0;#V=null;#W=new Set;#o=0;#Q;#X0=0;#Z0=!1;#M=0;#r;constructor(J){let{dragAndDrop:Q,fileTreeSearchMode:X,initialSearchQuery:Z,initialSelectedPaths:Y,renaming:W,onSearchChange:q,paths:G,preparedInput:$,...A}=J,K=r4({paths:G,preparedInput:$},"constructor",A.sort);if(this.#J=A,Q!=null&&Q!==!1)this.#z=Q===!0?{}:Q;if(this.#y=W!=null&&W!==!1,W!=null&&W!==!1&&W!==!0)this.#t=W.canRename,this.#p=W.onError,this.#c=W.onRename;this.#f=q,this.#i=X??"hide-non-matches",this.#Q=this.#W0(K.paths,K.preparedInput);let M=Y?.map((j)=>this.#S(j)).filter((j)=>j!=null)??[],U=M.at(-1)??null;if(M.length>0)this.#W=new Set(M),this.#V=U,this.#o=1;if(this.#m(U,!1),Z!=null)this.#a(Z,!1);this.#r=this.#R0()}destroy(){this.#r?.(),this.#r=null,this.#U.clear(),this.#X.clear(),this.#B.clear(),this.#q=null,this.#G0()}focusFirstItem(){if(this.#T().length>0)this.#C(0)}focusLastItem(){if(this.#M<=0)return;this.#N(),this.#C(this.#M-1)}focusNextItem(){this.#V0(1)}focusParentItem(){if(this.#Z==null)return;let J=W4(this.#Z);if(J==null)return;let Q=this.#g(J);if(Q>=0)this.#C(Q)}focusPath(J){let Q=this.#Q.getPathInfo(J)?.path??null;if(Q==null)return;this.#N();let X=this.#g(Q);if(X>=0)this.#C(X)}scrollToPath(J,Q){let X=this.#Q.getPathInfo(J)?.path??null;if(X==null)return;this.#N();let Z=this.#m0(X);if(Z<0)return;if(this.#$0(Z)==null)return;if(Q?.focus!==!1)this.#C(Z,!1);this.#e={id:this.#D0+=1,offset:RQ(Q?.offset),visibleIndex:Z},this.#K()}focusMountedPathFromInput(J){let Q=this.#Q.getPathInfo(J)?.path??null;if(Q==null)return;let X=this.#g(Q);if(X>=0)this.#C(X)}focusNearestPath(J){let Q=this.resolveNearestVisiblePath(J);if(Q==null)return null;let X=this.#g(Q);if(X>=0)return this.#C(X),this.#T()[X]??Q;return null}focusPreviousItem(){this.#V0(-1)}getFocusedIndex(){return this.#O}getFocusedItem(){return this.#Z==null?null:this.#U0(this.#Z)}getFocusedPath(){return this.#Z}getScrollRequest(){return this.#e}clearScrollRequest(J){if(this.#e?.id===J)this.#e=null}resolveNearestVisiblePath(J){let Q=this.#T();if(this.#M===0)return null;if(J==null)return this.#Z??Q[0]??null;let X=this.#Q.getPathInfo(J)?.path??J,Z=this.#g(X);if(Z>=0)return Q[Z]??X;let Y=this.#w0(X);if(Y!=null)return Y;return this.#Z??Q[0]??null}getSelectedPaths(){return[...this.#W]}getSelectionVersion(){return this.#o}getVisibleCount(){return this.#M}getVisibleRows(J,Q){if(Q<J||this.#M===0)return[];let X=Math.max(0,J),Z=Math.min(this.#M-1,Q);if(Z<X)return[];let Y=Z-X+1;if(this.#E==null&&!this.#L&&Z>=this.#Y.length&&Y<=VQ){let W=[];for(let q=X;q<=Z;q+=1){let G=this.#Q.getVisibleRowContext(q);if(G==null)break;W.push(this.#z0(G))}return W}if(!this.#L&&Z>=this.#Y.length)this.#N();if(this.#E!=null){let W=Array.from({length:Z-X+1},(A,K)=>this.#L0(X+K)),q=new Map,G=W[0]??-1,$=G;for(let A=1;A<=W.length;A+=1){let K=W[A];if(K!=null&&K===$+1){$=K;continue}if(G>=0)this.#Q.getVisibleSlice(G,$).forEach((M,U)=>{q.set(G+U,M)});if(K==null){G=-1,$=-1;continue}G=K,$=K}return Array.from({length:Z-X+1},(A,K)=>{let M=X+K,U=this.#L0(M),j=q.get(U),_=this.#Y[U];if(j==null||_==null)throw Error(`Missing projection row for filtered visible index ${String(M)}`);return this.#Y0(j,M,U,{ancestorPaths:this.#M0(U),path:_})})}return this.#Q.getVisibleSlice(X,Z).map((W,q)=>{let G=X+q,$=this.#Y[G];if($==null)throw Error(`Missing projection path for visible index ${String(G)}`);return this.#Y0(W,G,G,{ancestorPaths:this.#M0(G),path:$})})}getStickyRowCandidates(J,Q){if(this.#E!=null)return null;if(this.#M===0||J<=0||Q<=0)return[];let X=[];for(let Z=0;Z<this.#M;Z+=1){let Y=J+Z*Q,W=Math.min(this.#M-1,Math.floor(Y/Q)),q=this.#K0(W,Z)??(W>0?this.#K0(W-1,Z):void 0);if(q==null)break;X.push({row:this.#z0(q),subtreeEndIndex:q.subtreeEndIndex})}return X}getItem(J){let Q=this.#Q.getPathInfo(J);return Q==null?null:this.#U0(Q.path,Q)}resolveMountedDirectoryPathFromInput(J){let Q=this.#Q.getPathInfo(J);return Q?.kind==="directory"?Q.path:null}toggleMountedDirectoryFromInput(J){let Q=this.resolveMountedDirectoryPathFromInput(J);if(Q==null)return;this.#E0(Q)}selectAllVisiblePaths(){this.#N();let J=[...this.#T()];this.#R(J,this.#Z??this.#V)}selectOnlyPath(J){let Q=this.#S(J);if(Q==null)return;this.#R([Q],Q)}selectOnlyMountedPathFromInput(J){this.#R([J],J)}selectPath(J){let Q=this.#S(J);if(Q==null||this.#W.has(Q))return;this.#R([...this.#W,Q])}deselectPath(J){let Q=this.#S(J);if(Q==null||!this.#W.has(Q))return;this.#R([...this.#W].filter((X)=>X!==Q))}toggleFocusedSelection(){if(this.#Z==null)return;this.togglePathSelectionFromInput(this.#Z)}togglePathSelection(J){let Q=this.#S(J);if(Q==null)return;if(this.#W.has(Q)){this.deselectPath(Q);return}this.selectPath(Q)}togglePathSelectionFromInput(J){let Q=this.#S(J);if(Q==null)return;if(this.#W.has(Q)){this.#R([...this.#W].filter((X)=>X!==Q),Q);return}this.#R([...this.#W,Q],Q)}selectPathRange(J,Q){let X=this.#S(J);if(X==null)return;this.#N();let Z=this.#V,Y=Z==null?-1:this.#Q0(Z),W=this.#Q0(X);if(Y===-1||W===-1){let K=Q?[...this.#W,X]:[X];this.#R(K,X);return}let[q,G]=Y<=W?[Y,W]:[W,Y],$=this.#T().slice(q,G+1),A=Q?[...this.#W,...$]:$;this.#R(A,Z)}extendSelectionFromFocused(J){if(this.#Z==null)return;let Q=this.#O;if(Q===-1)return;let X=Math.min(this.#M-1,Math.max(0,Q+J));if(X===Q)return;if(!this.#L&&X>=this.#Y.length)this.#N();let Z=this.#T(),Y=Z[Q]??null,W=Z[X]??null;if(Y==null||W==null)return;let q=new Set(this.#W);if(q.has(Y)&&q.has(W))q.delete(Y);else q.add(W);this.#R([...q],this.#V??Y,!1),this.#C(X)}getDragAndDropConfig(){return this.#z}isDragAndDropEnabled(){return this.#z!=null}getDragSession(){if(this.#q==null)return null;return{draggedPaths:[...this.#q.draggedPaths],primaryPath:this.#q.primaryPath,target:this.#q.target==null?null:{...this.#q.target}}}startDrag(J){if(this.#z==null)return!1;let Q=this.#S(J);if(Q==null)return!1;if(this.#$!=null&&this.#$.length>0)return!1;let X=this.getSelectedPaths(),Z=I7(Q,X);if(this.#z.canDrag?.(Z)===!1)return!1;if(!X.includes(Q))this.#R([Q],Q,!1);return this.#n(Q),this.#q={draggedPaths:Z,primaryPath:Q,target:null},this.#K(),!0}setDragTarget(J){let Q=this.#q;if(Q==null)return;let X=J;if(X!=null){let Z=s4(Q.draggedPaths,X);if(o4(Q.draggedPaths,X)||this.#z?.canDrop?.(Z)===!1)X=null}if(u7(Q.target,X))return;this.#q={...Q,target:X},this.#K()}cancelDrag(){if(this.#q==null)return;this.#q=null,this.#K()}completeDrag(){let J=this.#q;if(J==null)return!1;this.#q=null;let Q=J.target==null?null:{...J.target};if(Q==null)return this.#K(),!1;let X=s4(J.draggedPaths,Q);if(o4(J.draggedPaths,Q)||this.#z?.canDrop?.(X)===!1)return this.#K(),!1;let Z=c7(J.draggedPaths,Q);if(Z==null)return this.#K(),!1;try{if(Z.operations.length===1){let Y=Z.operations[0];if(Y==null||Y.type!=="move")throw Error("Expected a single move operation for one-item drops");this.#Q.move(Y.from,Y.to,{collision:Y.collision})}else this.#v0(Z.operations),this.#Q.batch(Z.operations)}catch(Y){return this.#K(),this.#z?.onDropError?.(Y instanceof Error?Y.message:String(Y),X),!1}return this.#z?.onDropComplete?.(Z.result),!0}subscribe(J){return this.#X.add(J),J(),()=>{this.#X.delete(J)}}add(J){this.#Q.add(J)}remove(J,Q={}){this.#Q.remove(J,Q)}move(J,Q,X={}){this.#Q.move(J,Q,X)}batch(J){this.#Q.batch(J)}onMutation(J,Q){let X=J,Z=Q,Y=this.#U.get(X);if(Y==null)Y=new Set,this.#U.set(X,Y);return Y.add(Z),()=>{let W=this.#U.get(X);if(W?.delete(Z),W?.size===0)this.#U.delete(X)}}setSearch(J){this.#a(J,!0)}openSearch(J=""){this.#a(J,!0)}closeSearch(){this.#a(null,!0)}isSearchOpen(){return this.#$!==null}getSearchValue(){return this.#$??""}getSearchMatchingPaths(){return this.#d}focusNextSearchMatch(){this.#B0(1)}focusPreviousSearchMatch(){this.#B0(-1)}startRenaming(J=this.#Z??"",Q={}){if(!this.#y)return!1;let X=this.#Q.getPathInfo(J);if(X==null)return!1;let Z=X.path,Y=k3(Z),W=e4(Z);if(this.#t?.({isFolder:Y,path:W})===!1)return!1;for(let q of t0(Z))if(!this.#Q.isExpanded(q))this.#Q.expand(q);if(this.#R([Z],Z,!1),this.#$!=null)this.#a(null,!1),this.#f?.(this.#$);return this.#n(Z),this.#G=Z,this.#j=l7(Z),this.#w=Q.removeIfCanceled??!1,this.#K(),!0}[Q5](){return{cancel:()=>{this.#T0()},commit:()=>{this.#C0()},getPath:()=>this.#G,getValue:()=>this.#j,isActive:()=>this.#G!=null,setValue:(J)=>{this.#b0(J)}}}#T0(){if(this.#G==null)return;let J=this.#G,Q=this.#w;if(this.#G=null,this.#j="",this.#w=!1,Q){this.remove(J,k3(J)?{recursive:!0}:void 0);return}this.#n(J),this.#K()}#C0(){let J=this.#G;if(J==null)return;if(this.#w&&this.#j.trim().length===0){this.#G=null,this.#j="",this.#w=!1,this.remove(J,k3(J)?{recursive:!0}:void 0);return}let Q=k3(J),X=m7({files:this.#Q.list(),isFolder:Q,nextBasename:this.#j,path:e4(J)});if(this.#G=null,this.#j="",this.#w=!1,"error"in X){this.#n(J),this.#p?.(X.error),this.#K();return}if(X.sourcePath===X.destinationPath){this.#n(J),this.#K();return}this.#c?.({destinationPath:X.destinationPath,isFolder:X.isFolder,sourcePath:X.sourcePath}),this.move(J5(X.sourcePath,Q),J5(X.destinationPath,Q))}#b0(J){if(this.#G==null||this.#j===J)return;this.#j=J,this.#K()}resetPaths(J,Q={}){let X=this.#Q.list().length,Z=this.#M,Y=r4({paths:J,preparedInput:Q.preparedInput},"resetPaths",this.#J.sort),W=this.#W0(Y.paths,Y.preparedInput,Q.initialExpandedPaths),q=this.#Z,G=this.#G,$=this.getSelectedPaths(),A=this.#V;this.#r?.(),this.#Q=W,this.#B.clear(),this.#G0();let K=$.map((U)=>W.getPathInfo(U)?.path??null).filter((U)=>U!=null),M=!Y4(this.#W,K);if(this.#W=new Set(K),M)this.#o+=1;if(this.#V=A==null?null:W.getPathInfo(A)?.path??null,this.#G=G==null?null:W.getPathInfo(G)?.path??null,this.#G==null)this.#j="",this.#w=!1;this.#m(q,q!=null||K.length>0||this.#V!=null),this.#r=this.#R0(),this.#K(),this.#H0({canonicalChanged:!0,operation:"reset",pathCountAfter:Y.paths.length,pathCountBefore:X,projectionChanged:!0,usedPreparedInput:Q.preparedInput!=null,visibleCountDelta:this.#M-Z})}#w0(J){this.#N();let Q=W4(J),X=n4(J,Q),Z=null,Y=null;for(let W of this.#T()){if(W4(W)!==Q)continue;let q=n4(W,Q);if(q<X){Z=W;continue}if(q>X){Y=W;break}}return Z??Y}#g(J){let Q=this.#Q0(J);if(Q!==-1)return Q;let X=t0(J);for(let Z=X.length-1;Z>=0;Z-=1){let Y=X[Z];if(Y==null)continue;let W=this.#Q0(Y);if(W!==-1)return W}return this.#T().length>0?0:-1}#U0(J,Q){let X=this.#B.get(J);if(X!=null)return X;let Z=Q??this.#Q.getPathInfo(J);if(Z==null)return null;let Y=Z.kind==="directory"?this.#N0(Z.path):this.#y0(Z.path);return this.#B.set(Z.path,Y),Y}#Y0(J,Q,X,Z){return{ancestorPaths:Z.ancestorPaths,depth:J.depth,flattenedSegments:J.flattenedSegments?.map((Y)=>({isTerminal:Y.isTerminal,name:Y.name,path:Y.path})),hasChildren:J.hasChildren,index:Q,isExpanded:J.isExpanded,isFlattened:J.isFlattened,isFocused:Z.path===this.#Z,isSelected:this.#W.has(Z.path),kind:J.kind,level:J.depth,name:J.name,path:Z.path,posInSet:Z.posInSet??this.#h[X]??0,setSize:Z.setSize??this.#l[X]??0}}#z0(J){return this.#Y0(J.row,J.index,J.index,{ancestorPaths:J.ancestorPaths,path:J.row.path,posInSet:J.posInSet,setSize:J.setSize})}#K0(J,Q){let X=this.#Q.getVisibleRowContext(J);if(X==null)return;let Z=X.ancestorRows[Q];if(Z!=null)return Z;return Q===X.ancestorRows.length&&X.row.kind==="directory"&&X.row.isExpanded?X:void 0}#A0(J){let Q=this.#I.get(J);if(Q!=null)return Q;let X=this.#b(J),Z=X<0?[]:[...this.#A0(X),X];return this.#I.set(J,Z),Z}#M0(J){let Q=this.#u.get(J);if(Q!=null)return Q;let X=this.#A0(J).map((Z)=>this.#Y[Z]??"").filter((Z)=>Z!=="");return this.#u.set(J,X),X}#_0(J){this.#Q.collapse(J)}#R(J,Q=this.#V,X=!0){let Z=[...new Set(J)],Y=!Y4(this.#W,Z),W=this.#V!==Q;if(!Y&&!W)return;if(this.#W=new Set(Z),this.#V=Q,Y)this.#o+=1;if(X)this.#K()}#N0(J){return{collapse:()=>{this.#_0(J)},deselect:()=>{this.deselectPath(J)},expand:()=>{this.#k0(J)},focus:()=>{this.focusPath(J)},getPath:()=>J,isDirectory:()=>!0,isExpanded:()=>this.#Q.isExpanded(J),isFocused:()=>this.#Z===J,isSelected:()=>this.#W.has(J),select:()=>{this.selectPath(J)},toggleSelect:()=>{this.togglePathSelection(J)},toggle:()=>{this.#E0(J)}}}#y0(J){return{deselect:()=>{this.deselectPath(J)},focus:()=>{this.focusPath(J)},getPath:()=>J,isDirectory:()=>!1,isFocused:()=>this.#Z===J,isSelected:()=>this.#W.has(J),select:()=>{this.selectPath(J)},toggleSelect:()=>{this.togglePathSelection(J)}}}#v0(J){let Q=this.#Q.list();this.#W0(Q).batch(J)}#W0(J,Q,X){return new m1({...this.#J,paths:J,preparedInput:Q==null?void 0:Q,...X!==void 0?{initialExpandedPaths:X}:{}})}#q0(){if(this.#k!=null)return this.#k;return this.#k=this.#Q.list(),this.#k}#S0(){if(this.#H!=null)return this.#H;let J=new Set;for(let Q of this.#q0()){J.add(Q);for(let X of t0(Q))J.add(X)}return this.#H=[...J].sort(),this.#H}#f0(){if(this.#A!=null)return this.#A;return this.#A=this.#q0().map(t4),this.#A}#J0(){if(this.#_!=null)return this.#_;return this.#_=this.#S0().filter((J)=>J.endsWith("/")),this.#_}#P0(){if(this.#F!=null)return this.#F;return this.#F=this.#J0().map(t4),this.#F}#G0(){this.#_=null,this.#F=null,this.#H=null,this.#k=null,this.#A=null}#x0(){return this.#J0().filter((J)=>this.#Q.isExpanded(J))}#j0(J){let Q=new Set(this.#s??[]);if(J)for(let X of this.#W)for(let Z of t0(X))Q.add(Z);this.#O0(Q)}#O0(J){this.#Z0=!0;try{for(let Q of this.#J0()){let X=J.has(Q),Z=this.#Q.isExpanded(Q);if(X&&!Z)this.#Q.expand(Q);else if(!X&&Z)this.#Q.collapse(Q)}}finally{this.#Z0=!1}}#g0(){if(this.#$==null||this.#$.length===0){this.#d=[],this.#E=null,this.#x=null,this.#v=null,this.#M=this.#X0;return}let J=this.#Y;if(this.#d=J.filter((Y)=>this.#D.has(Y)),this.#i!=="hide-non-matches"||this.#D.size===0){this.#E=null,this.#x=null,this.#v=null,this.#M=this.#X0;return}let Q=[],X=[],Z=new Map;for(let[Y,W]of J.entries()){if(this.#P?.has(W)!==!0)continue;Z.set(W,X.length),Q.push(Y),X.push(W)}this.#E=Q,this.#x=X,this.#v=Z,this.#M=X.length}#T(){return this.#x??this.#Y}#m0(J){if(this.#x!=null)return this.#v?.get(J)??-1;return this.#Q.getVisibleIndex(J)??-1}#L0(J){return this.#E?.[J]??J}#Q0(J){let Q=this.#v?.get(J);if(Q!=null)return Q;return this.#Q.getVisibleIndex(J)??-1}#B0(J){let Q=this.#d;if(Q.length===0)return;let X=this.#Z,Z=X==null?-1:Q.indexOf(X),Y=Q[Z<0?J>0?0:Q.length-1:Math.min(Q.length-1,Math.max(0,Z+J))];if(Y!=null)this.focusPath(Y)}#a(J,Q){let X=J==null?null:d7(J),Z=this.#$;if(Z===X)return;if(Z==null&&X!=null)this.#s=this.#x0();if(this.#$=X,X==null)this.#j0(!0),this.#s=null,this.#D.clear(),this.#P=null,this.#m(this.#Z,!0);else if(X.length===0)this.#j0(!1),this.#D.clear(),this.#P=null,this.#m(this.#Z,!0);else{let Y=this.#F0();this.#m(Y,!0)}if(Q)this.#f?.(this.#$),this.#K()}#F0(){if(this.#$==null||this.#$.length===0)return this.#D.clear(),this.#Z;let J=this.#$,Q=this.#q0(),X=this.#f0(),Z=[],Y=new Set,W=null;for(let K=0;K<Q.length;K+=1){if(!X[K].includes(J))continue;let M=Q[K];Z.push(M),Y.add(M),W??=M}let q=this.#J0(),G=this.#P0();for(let K=0;K<q.length;K+=1){if(!G[K].includes(J))continue;let M=q[K];if(Y.has(M))continue;Z.push(M),Y.add(M),W??=M}this.#D=Y;let $=this.#i==="hide-non-matches"&&Z.length>0?new Set:null;this.#P=$;let A=this.#i==="expand-matches"?new Set(this.#s??[]):new Set;for(let K of Z){if($!=null)$.add(K);if(K.endsWith("/"))A.add(K);for(let M of t0(K))if(A.add(M),$!=null)$.add(M)}return this.#O0(A),W??this.#Z}#K(){for(let J of this.#X)J()}#H0(J){this.#U.get(J.operation)?.forEach((Q)=>{Q(J)}),this.#U.get("*")?.forEach((Q)=>{Q(J)})}#k0(J){for(let Q of t0(J)){if(this.#Q.isExpanded(Q))continue;this.#Q.expand(Q)}if(!this.#Q.isExpanded(J))this.#Q.expand(J)}#V0(J){let Q=this.#M;if(Q===0)return;let X=this.#O===-1?0:this.#O,Z=Math.min(Q-1,Math.max(0,X+J));if(Z!==X||this.#O===-1){if(!this.#L&&this.#E==null&&Z>=this.#Y.length)this.#N();this.#C(Z)}}#m(J,Q=!0){let X=this.#Q.getVisibleCount();this.#X0=X;let Z=DQ(this.#Q.getVisibleTreeProjectionData(Q?void 0:Math.min(X,kQ)),J,Q?(Y)=>this.#Q.getVisibleIndex(Y):void 0);this.#I.clear(),this.#u.clear(),this.#L=Z.paths.length>=X,this.#b=Z.getParentIndex,this.#Y=Z.paths,this.#h=Z.posInSetByIndex,this.#l=Z.setSizeByIndex,this.#g0(),this.#O=J==null?this.#T().length>0?0:-1:this.#g(J),this.#Z=this.#O<0?null:this.#$0(this.#O)}#$0(J){let Q=this.#T()[J];if(Q!=null)return Q;if(this.#E!=null)return null;return this.#Q.getVisibleRowContext(J)?.row.path??null}#S(J){return this.#Q.getPathInfo(J)?.path??null}#n(J){if(J==null)return;let Q=this.#g(J);if(Q>=0)this.#C(Q,!1)}#C(J,Q=!0){let X=this.#$0(J);if(X==null)return;if(this.#O===J&&this.#Z===X)return;if(this.#O=J,this.#Z=X,Q)this.#K()}#N(){if(this.#L)return;this.#m(this.#Z,!0)}#I0(J){let Q=p1(this.#G,J);if(Q==null&&this.#G!=null)this.#j="";this.#G=Q;let X=p1(this.#Z,J,!0),Z=[...this.#W].map((G)=>p1(G,J)).filter((G)=>G!=null).map((G)=>this.#Q.getPathInfo(G)?.path??null).filter((G)=>G!=null),Y=p1(this.#V,J),W=Y==null?null:this.#Q.getPathInfo(Y)?.path??null,q=[...new Set(Z)];if(!Y4(this.#W,q))this.#W=new Set(q),this.#o+=1;return this.#V=W,X}#R0(){return this.#Q.on("*",(J)=>{if(this.#Z0)return;if(J.canonicalChanged)this.#B.clear(),this.#G0();if(this.#q!=null&&a4(J))this.#q=null;let Q=a4(J)?this.#I0(J):this.#Z,X=this.#$!=null&&this.#$.length>0?this.#F0():this.#$===""?this.#Z:Q,Z=this.#$!=null||J.operation!=="expand"&&J.operation!=="collapse";this.#m(X,Z),this.#K();let Y=h7(J);if(Y!=null)this.#H0(Y)})}#E0(J){if(this.#Q.isExpanded(J)){this.#_0(J);return}this.#k0(J)}};var s7=(J)=>{if(J==null||J.length===0)return"0";let Q=`${J.length}`;for(let X of J)Q+=`\x00${X.path}\x00${X.status}`;return Q};function o7(J){let Q=J.endsWith("/"),X="",Z=-1;for(let Y=0;Y<=J.length;Y+=1){if(!(J[Y]==="/"||Y===J.length)){if(Z===-1)Z=Y;continue}if(Z===-1)continue;if(X!=="")X+="/";X+=J.slice(Z,Y),Z=-1}if(X==="")return null;return{isDirectory:Q,path:X}}function TQ(J){let Q=J.endsWith("/")?J.slice(0,-1):J;if(Q.length===0)return[];let X=Q.split("/");return X.slice(0,-1).map((Z,Y)=>`${X.slice(0,Y+1).join("/")}/`)}function CQ(J,Q){return Q?`${J}/`:J}function X5(J,Q=null){let X=s7(J==null?void 0:[...J]);if(X==="0")return null;if(Q?.signature===X)return Q;let Z=new Map,Y=new Set,W=new Set;for(let q of J??[]){let G=o7(q.path);if(G==null)continue;let $=CQ(G.path,G.isDirectory);if(Z.set($,q.status),q.status==="ignored"&&G.isDirectory)W.add($);else if(G.isDirectory)W.delete($);for(let A of TQ(G.path))Y.add(A)}return{directoriesWithChanges:Y,ignoredDirectoryPaths:W,signature:X,statusByPath:Z}}var bQ=(J)=>J.trim().toLowerCase(),wQ=(J)=>{return J.split("/").at(-1)??J},NQ=(J)=>{let Q=J.toLowerCase().split("."),X=[];for(let Z=1;Z<Q.length;Z+=1)X.push(Q.slice(Z).join("."));return X};function q4(J,Q){if(typeof J==="string")return{name:J,remappedFrom:Q};return{...J,remappedFrom:Q}}function r7(J){let Q=c1(J),X=Q.remap,Z=new Map;for(let[G,$]of Object.entries(Q.byFileName??{}))Z.set(G.toLowerCase(),$);let Y=new Map;for(let[G,$]of Object.entries(Q.byFileExtension??{}))Y.set(bQ(G),$);let W=Object.entries(Q.byFileNameContains??{}).map(([G,$])=>[G.toLowerCase(),$]);return{resolveIcon:(G,$)=>{if(G==="file-tree-icon-file"&&$!=null){let K=wQ($),M=K.toLowerCase(),U=Z.get(M);if(U!=null)return q4(U,G);for(let[F,k]of W)if(M.includes(F))return q4(k,G);let j=NQ(K);for(let F of j){let k=Y.get(F);if(k!=null)return q4(k,G)}let _=b7(Q.set,K,j);if(_!=null&&Q.set!=="none")return{name:T7(_),remappedFrom:G,token:_}}let A=X?.[G];if(A==null)return{name:G};return q4(A,G)}}}var I,J8,yQ,R1,a7,z4,Q8,X8,q5,Z5,Y5,vQ,V3={},Z8=[],K4=Array.isArray,G5=Z8.slice,U1=Object.assign;function $5(J){J&&J.parentNode&&J.remove()}function l1(J,Q,X){var Z,Y,W,q={};for(W in Q)W=="key"?Z=Q[W]:W=="ref"&&typeof J!="function"?Y=Q[W]:q[W]=Q[W];return arguments.length>2&&(q.children=arguments.length>3?G5.call(arguments,2):X),$4(J,q,Z,Y,null)}function $4(J,Q,X,Z,Y){var W={type:J,props:Q,key:X,ref:Z,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:Y==null?++J8:Y,__i:-1,__u:0};return Y==null&&I.vnode!=null&&I.vnode(W),W}function l0(J){return J.children}function U4(J,Q){this.props=J,this.context=Q,this.__g=0}function h1(J,Q){if(Q==null)return J.__?h1(J.__,J.__i+1):null;for(var X;Q<J.__k.length;Q++)if((X=J.__k[Q])!=null&&X.__e!=null)return X.__e;return typeof J.type=="function"?h1(J):null}function Y8(J){var Q,X;if((J=J.__)!=null&&J.__c!=null){for(J.__e=null,Q=0;Q<J.__k.length;Q++)if((X=J.__k[Q])!=null&&X.__e!=null){J.__e=X.__e;break}return Y8(J)}}function n7(J){(8&J.__g||!(J.__g|=8)||!R1.push(J)||z4++)&&a7==I.debounceRendering||((a7=I.debounceRendering)||queueMicrotask)(SQ)}function SQ(){for(var J,Q,X,Z,Y,W,q,G,$=1;R1.length;)R1.length>$&&R1.sort(Q8),J=R1.shift(),$=R1.length,8&J.__g&&(X=void 0,Y=(Z=(Q=J).__v).__e,W=[],q=[],(G=Q.__P)&&((X=U1({},Z)).__v=Z.__v+1,I.vnode&&I.vnode(X),U5(G,X,Z,Q.__n,G.namespaceURI,32&Z.__u?[Y]:null,W,Y==null?h1(Z):Y,!!(32&Z.__u),q,G.ownerDocument),X.__v=Z.__v,X.__.__k[X.__i]=X,G8(W,X,q),X.__e!=Y&&Y8(X)));z4=0}function W8(J,Q,X,Z,Y,W,q,G,$,A,K,M){var U,j,_,F,k,b,E,L=Z&&Z.__k||Z8,B=Q.length;for($=fQ(X,Q,L,$,B),U=0;U<B;U++)(_=X.__k[U])!=null&&(j=_.__i==-1?V3:L[_.__i]||V3,_.__i=U,b=U5(J,_,j,Y,W,q,G,$,A,K,M),F=_.__e,_.ref&&j.ref!=_.ref&&(j.ref&&z5(j.ref,null,_),K.push(_.ref,_.__c||F,_)),k==null&&F!=null&&(k=F),(E=!!(4&_.__u))||j.__k===_.__k?$=q8(_,$,J,E):typeof _.type=="function"&&b!==void 0?$=b:F&&($=F.nextSibling),_.__u&=-7);return X.__e=k,$}function fQ(J,Q,X,Z,Y){var W,q,G,$,A,K=X.length,M=K,U=0;for(J.__k=Array(Y),W=0;W<Y;W++)(q=Q[W])!=null&&typeof q!="boolean"&&typeof q!="function"?($=W+U,(q=J.__k[W]=typeof q=="string"||typeof q=="number"||typeof q=="bigint"||q.constructor==String?$4(null,q,null,null,null):K4(q)?$4(l0,{children:q},null,null,null):q.constructor==null&&q.__b>0?$4(q.type,q.props,q.key,q.ref?q.ref:null,q.__v):q).__=J,q.__b=J.__b+1,G=null,(A=q.__i=PQ(q,X,$,M))!=-1&&(M--,(G=X[A])&&(G.__u|=2)),G==null||G.__v==null?(A==-1&&(Y>K?U--:Y<K&&U++),typeof q.type!="function"&&(q.__u|=4)):A!=$&&(A==$-1?U--:A==$+1?U++:(A>$?U--:U++,q.__u|=4))):J.__k[W]=null;if(M)for(W=0;W<K;W++)(G=X[W])!=null&&(2&G.__u)==0&&(G.__e==Z&&(Z=h1(G)),U8(G,G));return Z}function q8(J,Q,X,Z){var Y,W;if(typeof J.type=="function"){for(Y=J.__k,W=0;Y&&W<Y.length;W++)Y[W]&&(Y[W].__=J,Q=q8(Y[W],Q,X,Z));return Q}J.__e!=Q&&(Z&&(Q&&J.type&&!Q.parentNode&&(Q=h1(J)),X.insertBefore(J.__e,Q||null)),Q=J.__e);do Q=Q&&Q.nextSibling;while(Q!=null&&Q.nodeType==8);return Q}function PQ(J,Q,X,Z){var Y,W,q,G=J.key,$=J.type,A=Q[X],K=A!=null&&(2&A.__u)==0;if(A===null&&J.key==null||K&&G==A.key&&$==A.type)return X;if(Z>(K?1:0)){for(Y=X-1,W=X+1;Y>=0||W<Q.length;)if((A=Q[q=Y>=0?Y--:W++])!=null&&(2&A.__u)==0&&G==A.key&&$==A.type)return q}return-1}function t7(J,Q,X){Q[0]=="-"?J.setProperty(Q,X==null?"":X):J[Q]=X==null?"":X}function G4(J,Q,X,Z,Y){var W;J:if(Q=="style")if(typeof X=="string")J.style.cssText=X;else{if(typeof Z=="string"&&(J.style.cssText=Z=""),Z)for(Q in Z)X&&Q in X||t7(J.style,Q,"");if(X)for(Q in X)Z&&X[Q]==Z[Q]||t7(J.style,Q,X[Q])}else if(Q[0]=="o"&&Q[1]=="n")W=Q!=(Q=Q.replace(X8,"$1")),(Q=Q.slice(2))[0].toLowerCase()!=Q[0]&&(Q=Q.toLowerCase()),J.__l||(J.__l={}),J.__l[Q+W]=X,X?Z?X.l=Z.l:(X.l=q5,J.addEventListener(Q,W?Y5:Z5,W)):J.removeEventListener(Q,W?Y5:Z5,W);else{if(Y=="http://www.w3.org/2000/svg")Q=Q.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(Q!="width"&&Q!="height"&&Q!="href"&&Q!="list"&&Q!="form"&&Q!="tabIndex"&&Q!="download"&&Q!="rowSpan"&&Q!="colSpan"&&Q!="role"&&Q!="popover"&&Q in J)try{J[Q]=X==null?"":X;break J}catch(q){}typeof X=="function"||(X==null||X===!1&&Q[4]!="-"?J.removeAttribute(Q):J.setAttribute(Q,Q=="popover"&&X==1?"":X))}}function e7(J){return function(Q){if(this.__l){var X=this.__l[Q.type+J];if(Q.u==null)Q.u=q5++;else if(Q.u<X.l)return;return X(I.event?I.event(Q):Q)}}}function U5(J,Q,X,Z,Y,W,q,G,$,A,K){var M,U,j,_,F,k,b,E,L,B,H,w,P,U0,o,_0,a,e,$0,J0,S0,d=Q.type;if(Q.constructor!=null)return null;128&X.__u&&($=!!(32&X.__u),X.__c.__z&&(G=Q.__e=X.__e=(W=X.__c.__z)[0],X.__c.__z=null)),(M=I.__b)&&M(Q);J:if(typeof d=="function")try{if(E=Q.props,L="prototype"in d&&d.prototype.render,B=(M=d.contextType)&&Z[M.__c],H=M?B?B.props.value:M.__:Z,X.__c?2&(U=Q.__c=X.__c).__g&&(U.__g|=1,b=!0):(L?Q.__c=U=new d(E,H):(Q.__c=U=new U4(E,H),U.constructor=d,U.render=gQ),B&&B.sub(U),U.props=E,U.state||(U.state={}),U.context=H,U.__n=Z,j=!0,U.__g|=8,U.__h=[],U._sb=[]),L&&U.__s==null&&(U.__s=U.state),L&&d.getDerivedStateFromProps!=null&&(U.__s==U.state&&(U.__s=U1({},U.__s)),U1(U.__s,d.getDerivedStateFromProps(E,U.__s))),_=U.props,F=U.state,U.__v=Q,j)L&&d.getDerivedStateFromProps==null&&U.componentWillMount!=null&&U.componentWillMount(),L&&U.componentDidMount!=null&&U.__h.push(U.componentDidMount);else{if(L&&d.getDerivedStateFromProps==null&&E!==_&&U.componentWillReceiveProps!=null&&U.componentWillReceiveProps(E,H),!(4&U.__g)&&U.shouldComponentUpdate!=null&&U.shouldComponentUpdate(E,U.__s,H)===!1||Q.__v==X.__v){for(Q.__v!=X.__v&&(U.props=E,U.state=U.__s,U.__g&=-9),Q.__e=X.__e,Q.__k=X.__k,Q.__k.some(function(Y0){Y0&&(Y0.__=Q)}),w=0;w<U._sb.length;w++)U.__h.push(U._sb[w]);U._sb=[],U.__h.length&&q.push(U);break J}U.componentWillUpdate!=null&&U.componentWillUpdate(E,U.__s,H),L&&U.componentDidUpdate!=null&&U.__h.push(function(){U.componentDidUpdate(_,F,k)})}if(U.context=H,U.props=E,U.__P=J,U.__g&=-5,P=I.__r,U0=0,L){for(U.state=U.__s,U.__g&=-9,P&&P(Q),M=U.render(U.props,U.state,U.context),o=0;o<U._sb.length;o++)U.__h.push(U._sb[o]);U._sb=[]}else do U.__g&=-9,P&&P(Q),M=U.render(U.props,U.state,U.context),U.state=U.__s;while(8&U.__g&&++U0<25);U.state=U.__s,U.getChildContext!=null&&(Z=U1({},Z,U.getChildContext())),L&&!j&&U.getSnapshotBeforeUpdate!=null&&(k=U.getSnapshotBeforeUpdate(_,F)),_0=M,M!=null&&M.type===l0&&M.key==null&&(_0=$8(M.props.children)),G=W8(J,K4(_0)?_0:[_0],Q,X,Z,Y,W,q,G,$,A,K),Q.__u&=-161,U.__h.length&&q.push(U),b&&(U.__g&=-4)}catch(Y0){if(Q.__v=null,$||W!=null)if(Y0.then){for(a=0,e=!1,Q.__u|=$?160:128,Q.__c.__z=[],$0=0;$0<W.length;$0++)(J0=W[$0])==null||e||(J0.nodeType==8&&J0.data=="$s"?(a>0&&Q.__c.__z.push(J0),a++,W[$0]=null):J0.nodeType==8&&J0.data=="/$s"?(--a>0&&Q.__c.__z.push(J0),e=a===0,G=W[$0],W[$0]=null):a>0&&(Q.__c.__z.push(J0),W[$0]=null));if(!e){for(;G&&G.nodeType==8&&G.nextSibling;)G=G.nextSibling;W[W.indexOf(G)]=null,Q.__c.__z=[G]}Q.__e=G}else{for(S0=W.length;S0--;)$5(W[S0]);W5(Q)}else Q.__e=X.__e,Q.__k=X.__k,Y0.then||W5(Q);I.__e(Y0,Q,X)}else G=Q.__e=xQ(X.__e,Q,X,Z,Y,W,q,$,A,K);return(M=I.diffed)&&M(Q),128&Q.__u?void 0:G}function W5(J){J&&J.__c&&(J.__c.__g|=4),J&&J.__k&&J.__k.forEach(W5)}function G8(J,Q,X){for(var Z=0;Z<X.length;Z++)z5(X[Z],X[++Z],X[++Z]);I.__c&&I.__c(Q,J),J.some(function(Y){try{J=Y.__h,Y.__h=[],J.some(function(W){W.call(Y)})}catch(W){I.__e(W,Y.__v)}})}function $8(J){return typeof J!="object"||J==null||J.__b&&J.__b>0?J:K4(J)?J.map($8):U1({},J)}function xQ(J,Q,X,Z,Y,W,q,G,$,A){var K,M,U,j,_,F,k,b,E=X.props,L=Q.props,B=Q.type;if(B=="svg"?Y="http://www.w3.org/2000/svg":B=="math"?Y="http://www.w3.org/1998/Math/MathML":Y||(Y="http://www.w3.org/1999/xhtml"),W!=null){for(K=0;K<W.length;K++)if((_=W[K])&&"setAttribute"in _==!!B&&(B?_.localName==B:_.nodeType==3)){J=_,W[K]=null;break}}if(J==null){if(B==null)return A.createTextNode(L);J=A.createElementNS(Y,B,L.is&&L),G&&(I.__m&&I.__m(Q,W),G=!1),W=null}if(B==null)E===L||G&&J.data==L||(J.data=L);else{if(W=W&&G5.call(J.childNodes),E=X.props||V3,!G&&W!=null)for(E={},K=0;K<J.attributes.length;K++)E[(_=J.attributes[K]).name]=_.value;for(K in E)if(_=E[K],K=="children");else if(K=="dangerouslySetInnerHTML")U=_;else if(!(K in L)){if(K=="value"&&"defaultValue"in L||K=="checked"&&"defaultChecked"in L)continue;G4(J,K,null,_,Y)}for(K in b=1&X.__u,L)_=L[K],K=="children"?j=_:K=="dangerouslySetInnerHTML"?M=_:K=="value"?F=_:K=="checked"?k=_:G&&typeof _!="function"||E[K]===_&&!b||G4(J,K,_,E[K],Y);if(M)G||U&&(M.__html==U.__html||M.__html==J.innerHTML)||(J.innerHTML=M.__html),Q.__k=[];else if(U&&(J.innerHTML=""),W8(B=="template"?J.content:J,K4(j)?j:[j],Q,X,Z,B=="foreignObject"?"http://www.w3.org/1999/xhtml":Y,W,q,W?W[0]:X.__k&&h1(X,0),G,$,A),W!=null)for(K=W.length;K--;)$5(W[K]);G||(K="value",B=="progress"&&F==null?J.removeAttribute("value"):F==null||F===J[K]&&(B!=="progress"||F)||G4(J,K,F,E[K],Y),K="checked",k!=null&&k!=J[K]&&G4(J,K,k,E[K],Y))}return J}function z5(J,Q,X){try{if(typeof J=="function"){var Z=typeof J.__u=="function";Z&&J.__u(),Z&&Q==null||(J.__u=J(Q))}else J.current=Q}catch(Y){I.__e(Y,X)}}function U8(J,Q,X){var Z,Y;if(I.unmount&&I.unmount(J),(Z=J.ref)&&(Z.current&&Z.current!=J.__e||z5(Z,null,Q)),(Z=J.__c)!=null){if(Z.componentWillUnmount)try{Z.componentWillUnmount()}catch(W){I.__e(W,Q)}Z.__P=null}if(Z=J.__k)for(Y=0;Y<Z.length;Y++)Z[Y]&&U8(Z[Y],Q,X||typeof J.type!="function");X||$5(J.__e),J.__e&&J.__e.__l&&(J.__e.__l=null),J.__e=J.__c=J.__=null}function gQ(J,Q,X){return this.constructor(J,X)}function A4(J,Q){var X,Z,Y,W;Q==document&&(Q=document.documentElement),I.__&&I.__(J,Q),Z=(X=!!(J&&32&J.__u))?null:Q.__k,J=Q.__k=l1(l0,null,[J]),Y=[],W=[],U5(Q,J,Z||V3,V3,Q.namespaceURI,Z?null:Q.firstChild?G5.call(Q.childNodes):null,Y,Z?Z.__e:Q.firstChild,X,W,Q.ownerDocument),G8(Y,J,W)}function z8(J,Q){J.__u|=32,A4(J,Q)}I={__e:function(J,Q,X,Z){for(var Y,W,q;Q=Q.__;)if((Y=Q.__c)&&!(1&Y.__g)){Y.__g|=4;try{if((W=Y.constructor)&&W.getDerivedStateFromError!=null&&(Y.setState(W.getDerivedStateFromError(J)),q=8&Y.__g),Y.componentDidCatch!=null&&(Y.componentDidCatch(J,Z||{}),q=8&Y.__g),q)return void(Y.__g|=2)}catch(G){J=G}}throw z4=0,J}},J8=0,yQ=function(J){return J!=null&&J.constructor==null},U4.prototype.setState=function(J,Q){var X;X=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=U1({},this.state),typeof J=="function"&&(J=J(U1({},X),this.props)),J&&U1(X,J),J!=null&&this.__v&&(Q&&this._sb.push(Q),n7(this))},U4.prototype.forceUpdate=function(J){this.__v&&(this.__g|=4,J&&this.__h.push(J),n7(this))},U4.prototype.render=l0,R1=[],z4=0,Q8=function(J,Q){return J.__v.__b-Q.__v.__b},X8=/(PointerCapture)$|Capture$/i,q5=0,Z5=e7(!1),Y5=e7(!0),vQ=0;var mQ=0;function V(J,Q,X,Z,Y,W){Q||(Q={});var q,G,$=Q;if("ref"in $&&typeof J!="function")for(G in $={},Q)G=="ref"?q=Q[G]:$[G]=Q[G];var A={type:J,props:$,key:X,ref:q,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:--mQ,__i:-1,__u:0,__source:Y,__self:W};return I.vnode&&I.vnode(A),A}var IQ=16,uQ=16,cQ={};function d1({name:J,remappedFrom:Q,token:X,width:Z,height:Y,viewBox:W,label:q,alignCapitals:G=!1}){let $=`#${J.replace(/^#/,"")}`,{width:A,height:K,viewBox:M}=cQ[J]??{width:IQ,height:uQ},U=Z??A,j=Y??K,_=W??M??`0 0 ${A} ${K}`,F=q!=null?{"aria-label":q,role:"img"}:{"aria-hidden":!0};return V("svg",{"data-icon-name":Q??J,"data-icon-token":X,"data-align-capitals":G,...F,viewBox:_,width:U,height:j,children:V("use",{href:$})})}var K8=(J)=>{if(J.length<2)return[J,""];let Q=Math.ceil(J.length/2);return[J.slice(0,Q),J.slice(Q)]},pQ=(J)=>{if(J.length<4)return[J,""];let Q=J.lastIndexOf(".")+1,X=J.length-Q>10,Z=Q>=1&&!X?Q:Math.ceil(J.length/2);return[J.slice(0,Z),J.slice(Z)]},hQ=(J)=>{if(J.length<4)return[J,""];let Q=J.lastIndexOf("/")+1,X=J.length-Q>25,Z=Q>=1&&!X?Q:Math.ceil(J.length/2);return[J.slice(0,Z),J.slice(Z)]},lQ=(J,{splitIndex:Q}={})=>{if(typeof Q!=="number"){let X=Math.ceil(J.length/2);return[J.slice(0,X),J.slice(X)]}return[J.slice(0,Q),J.slice(Q)]},dQ=(J,{splitOffset:Q}={})=>{if(typeof Q!=="number"||Q<=0||Q>=J.length){let Z=Math.ceil(J.length/2);return[J.slice(0,Z),J.slice(Z)]}let X=J.length-Q;return[J.slice(0,X),J.slice(X)]},iQ=(J,{splitOffset:Q}={})=>{if(typeof Q!=="number"||Q<=0||Q>=J.length){let Z=Math.ceil(J.length/2);return[J.slice(0,Z),J.slice(Z)]}let X=Q;return[J.slice(0,X),J.slice(X)]};function sQ({children:J,marker:Q,variant:X="default"}){return V("div",{"aria-hidden":!0,"data-truncate-marker-cell":!0,children:V("div",{"data-truncate-marker":!0,children:typeof Q==="function"?Q({children:J}):X==="fade"?V("span",{"data-truncate-fade":!0}):Q})})}function oQ(J){let{mode:Q,children:X}=J;return V("div",{children:[V("div",{"data-truncate-content":"visible",children:Q==="fruncate"?V("span",{children:X}):X}),V("div",{"data-truncate-content":"overflow","aria-hidden":!0,children:Q==="fruncate"?V("span",{children:X}):X})]})}function A8({children:J,mode:Q="truncate",marker:X="…",variant:Z="default",...Y}){let W=V(oQ,{mode:Q,children:J},"content"),q=V(sQ,{marker:X,mode:Q,variant:Z},"marker");return V("div",{"data-truncate-container":Q,"data-truncate-variant":Z,...Y,children:V("div",{"data-truncate-grid":!0,children:Q==="truncate"?[W,q]:[q,W,V("div",{"data-truncate-fill":!0},"fill")]})})}function R3({children:J,...Q}){return V(A8,{mode:"truncate",...Q,children:J})}function K5({children:J,...Q}){return V(A8,{mode:"fruncate",...Q,children:J})}function M8({children:J,contents:Q,priority:X="end",split:Z="center",minimumLength:Y=12,className:W,style:q,...G}){let $=null,A=null;if(Array.isArray(Q)){if(Q.length!==2)return console.error("MiddleTruncate: contents must be an array of two items"),null;$=V(R3,{...G,children:Q[0]}),A=V(K5,{...G,children:Q[1]})}else{if(typeof J!=="string")return console.error("MiddleTruncate: children must be a string"),null;if(J.length===0)return V("div",{className:W,style:q});if(J.length<Y)if(X==="end")return V(K5,{...G,className:W,style:q,children:J});else return V(R3,{...G,className:W,style:q,children:J});let K=null,M=null,U=null;if(typeof Z==="string"){if(Z==="center")K=K8;else if(Z==="extension")K=pQ;else if(Z==="leaf-path")K=hQ}else if(typeof Z==="number")K=lQ,M=Z;else if(Array.isArray(Z)){let[B,H]=Z;if(U=H,B==="last")K=dQ;else if(B==="first")K=iQ}else if(typeof Z==="function")K=Z;K??=K8;let[j,_]=K(J,{priority:X,variant:G.variant,splitIndex:typeof M==="number"?M:void 0,splitOffset:typeof U==="number"?U:void 0}),F=j.length>=_.length,k=X==="equal"&&!F,b=X==="equal"&&F,E={},L={};if(k)E.marker="";if(b)L.marker="";$=V(R3,{...G,...E,children:j}),A=V(K5,{...G,...L,children:_})}return V("div",{"data-truncate-group-container":"middle",className:W,style:q,children:[V("div",{"data-truncate-segment-priority":X==="start"||X==="equal"?"1":"2",children:$}),V("div",{"data-truncate-segment-priority":X==="end"||X==="equal"?"1":"2",children:A})]})}var A5={endIndex:-1,startIndex:-1};function rQ(J,Q,X){return Math.min(Math.max(J,Q),X)}function _8(J,Q){return J<0||Q<J?A5:{endIndex:Q,startIndex:J}}function M5(J){return J.startIndex<0||J.endIndex<J.startIndex}function aQ(J,Q){return M5(J)?0:(J.endIndex-J.startIndex+1)*Q}function j8(J,Q,X){if(Q<=0)return-1;let Z=Q*X;if(J<=0)return 0;if(J>=Z)return Q;return Math.floor(J/X)}function nQ(J,Q,X){if(Q<=0||J<=0)return-1;if(J>=Q*X)return Q-1;return Math.ceil(J/X)-1}function tQ(J){let Q=new Map;return J.forEach((X,Z)=>{if(X.kind!=="directory"||!X.isExpanded)return;let Y=X.ancestorPaths.length,W=Q.get(Y);if(W==null){Q.set(Y,[Z]);return}W.push(Z)}),Q}function eQ(J,Q){let X=0,Z=J.length-1,Y=-1;while(X<=Z){let W=Math.floor((X+Z)/2),q=J[W];if(q==null)break;if(q<=Q){Y=W,X=W+1;continue}Z=W-1}return Y}function JX(J){let Q=new Map,X=[];for(let Y=0;Y<J.length;Y+=1){let W=J[Y];if(W==null)continue;let q=W.kind==="directory"&&W.isExpanded?[...W.ancestorPaths,W.path]:W.ancestorPaths,G=0;while(G<X.length&&G<q.length&&X[G]===q[G])G+=1;for(let $=X.length-1;$>=G;$-=1){let A=X[$];if(A!=null)Q.set(A,Y-1)}X.length=G;for(let $=G;$<q.length;$+=1){let A=q[$];if(A!=null)X.push(A)}}let Z=J.length-1;for(let Y of X)Q.set(Y,Z);return Q}function _5(J,Q,X){if(J.length===0||Q<=0)return[];let Z=JX(J),Y=tQ(J),W=[];for(let q=0;q<J.length;q+=1){let G=Y.get(q);if(G==null||G.length===0)break;let $=Q+q*X,A=eQ(G,Math.min(J.length-1,Math.floor($/X))),K=null;while(A>=0){let M=G[A],U=M==null?null:J[M]??null;if(U!=null&&(q===0||U.ancestorPaths[q-1]===W[q-1]?.path)){K=U;break}A-=1}if(K==null)break;W.push(K)}return W.map((q,G)=>{let $=G*X,A=(Z.get(q.path)??J.length-1)+1;if(A>=J.length)return{row:q,top:$};let K=A*X-Q;return{row:q,top:Math.min($,K-X)}}).filter((q)=>q.top+X>0)}function O8(J,Q){let X=Q.totalRowCount??J.length,Z=X*Q.itemHeight,Y=Math.max(0,Q.viewportHeight),W=Math.max(0,Math.floor(Q.overscan)),q=Math.max(0,Z-Y),G=rQ(Q.scrollTop,0,q),$=Q.stickyRows??_5(J,G,Q.itemHeight),A=$.reduce((w,P)=>Math.max(w,P.top+Q.itemHeight),0),K=Math.min(Z,G+A),M=Math.max(0,Y-A),U=Math.max(0,Z-K),j=j8(G,X,Q.itemHeight),_=j8(K,X,Q.itemHeight),F=A<=0||j<0||j>=X?-1:j,k=F===-1?-1:Math.min(X-1,_-1),b=F===-1||k<F?0:k-F+1,E=M<=0||_>=X?A5:_8(_,nQ(K+M,X,Q.itemHeight)),L=k+1,B=M5(E)?A5:_8(Math.max(L,E.startIndex-W),Math.min(X-1,E.endIndex+W)),H=aQ(B,Q.itemHeight);return{occlusion:{firstOccludedIndex:F,lastOccludedIndex:k,occludedCount:b},physical:{itemHeight:Q.itemHeight,maxScrollTop:q,overscan:W,scrollTop:G,totalHeight:Z,totalRowCount:X,viewportHeight:Y},projected:{contentHeight:U,paneHeight:M,paneTop:K},sticky:{height:A,rows:$},visible:E,window:{endIndex:B.endIndex,height:H,offsetTop:M5(B)?0:B.startIndex*Q.itemHeight,startIndex:B.startIndex}}}var L8={added:"A",deleted:"D",ignored:null,modified:"M",renamed:"R",untracked:"U"},B8={added:"Git status: added",deleted:"Git status: deleted",ignored:"Git status: ignored",modified:"Git status: modified",renamed:"Git status: renamed",untracked:"Git status: untracked"},F8="Contains git status items";function j5(J){let{currentScrollTop:Q,focusedIndex:X,itemHeight:Z,topInset:Y=0,viewportHeight:W}=J;if(X<0)return null;let q=Math.max(0,Y),G=X*Z,$=G+Z;if(G<Q+q){let A=Math.max(0,G-q);return A===Q?null:A}if($>Q+W){let A=$-W;return A===Q?null:A}return null}function H8(J){let{currentScrollTop:Q,focusedIndex:X,itemHeight:Z,offset:Y,topInset:W=0,totalHeight:q,viewportHeight:G}=J;if(Y==="nearest")return j5({currentScrollTop:Q,focusedIndex:X,itemHeight:Z,topInset:W,viewportHeight:G});if(X<0)return null;let $=Math.max(0,W),A=X*Z,K=Math.max(0,G-$),M=Y==="center"?$+Math.max(0,(K-Z)/2):$,U=Math.max(0,q-G),j=Math.max(0,Math.min(A-M,U));return j===Q?null:j}function k8(J){let{currentScrollTop:Q,focusedIndex:X,itemHeight:Z,targetViewportOffset:Y,totalHeight:W,viewportHeight:q}=J;if(X<0)return null;let G=Math.max(0,Y),$=X*Z,A=$+Z,K=Q+G,M=Q+q;if($>=K&&A<=M)return null;let U=Math.max(0,W-q),j=Math.max(0,Math.min($-G,U));return j===Q?null:j}function E1(J){if(J==null||!J.isConnected)return!1;if(J===document.body||J===document.documentElement)return!1;J.focus({preventScroll:!0});let Q=J.getRootNode();if(Q instanceof ShadowRoot)return Q.activeElement===J;return document.activeElement===J}function E3(J){let Q=J.getRootNode();if(Q instanceof ShadowRoot){let Z=Q.activeElement;return Z instanceof HTMLElement?Z:null}let X=document.activeElement;return X instanceof HTMLElement&&J.contains(X)?X:null}function i1(J,Q){if(J==null)return Q;let X=J.getBoundingClientRect().height;if(X>0)return X;return J.clientHeight>0?J.clientHeight:Q}function O5(J,Q){return J!=null&&J>0?J:Q}function V8(J){let Q=J.borderBoxSize,X=Array.isArray(Q)?Q[0]:Q;if(X!=null&&Number.isFinite(X.blockSize)&&X.blockSize>0)return X.blockSize;return J.contentRect.height>0?J.contentRect.height:null}function L5(J,Q,X,Z,Y=0){let W=j5({currentScrollTop:J.scrollTop,focusedIndex:Q,itemHeight:X,topInset:Y,viewportHeight:Z});if(W==null)return!1;return J.scrollTop=W,!0}function R8(J,Q,X,Z,Y,W,q=0){let G=H8({currentScrollTop:J.scrollTop,focusedIndex:Q,itemHeight:X,offset:W,topInset:q,totalHeight:Y,viewportHeight:Z});if(G==null)return!1;return J.scrollTop=G,!0}function s1(J,Q,X,Z,Y,W){let q=k8({currentScrollTop:J.scrollTop,focusedIndex:Q,itemHeight:X,targetViewportOffset:W,totalHeight:Y,viewportHeight:Z});if(q==null)return!1;return J.scrollTop=q,!0}function B5(J,Q,X,Z){if(X.end<X.start)return null;if(J<X.start)return-Q;if(J>X.end)return Z;return null}function E8(J){let{renamingPath:Q,previousRenamingPath:X,hasRenderedInput:Z}=J;if(Q==null)return"reset";if(!Z)return"reveal-canonical";if(X===Q)return"ignore";return"focus-input"}function D8({ariaLabel:J,isFlattened:Q=!1,ref:X,value:Z,onBlur:Y,onInput:W}){return V("input",{ref:X,"data-item-rename-input":!0,...Q?{"data-item-flattened-rename-input":!0}:{},"aria-label":J,value:Z,onBlur:Y,onInput:W,onClick:(q)=>q.stopPropagation(),onMouseDown:(q)=>q.stopPropagation(),onPointerDown:(q)=>q.stopPropagation()})}function T8(J){let{row:Q,mode:X,targetPath:Z,ariaLabel:Y,domId:W,isParked:q,itemHeight:G,features:$,state:A,extraStyle:K}=J,M=X==="sticky",U=Q.ancestorPaths.at(-1)??"",j={};if(A.isFocusRinged)j["data-item-focused"]=!0;if(Q.isSelected)j["data-item-selected"]=!0;if(A.isContextHovered)j["data-item-context-hover"]="true";if(A.isDragTarget)j["data-item-drag-target"]=!0;if(A.isDragging)j["data-item-dragging"]=!0;if(A.effectiveGitStatus!=null)j["data-item-git-status"]=A.effectiveGitStatus;if(A.containsGitChange)j["data-item-contains-git-change"]="true";return{"aria-expanded":!M&&Q.kind==="directory"?Q.isExpanded:void 0,"aria-haspopup":$.contextMenuEnabled?"menu":void 0,"aria-label":Y,"aria-level":!M?Q.level+1:void 0,"aria-posinset":!M?Q.posInSet+1:void 0,"aria-selected":!M?Q.isSelected?"true":"false":void 0,"aria-setsize":!M?Q.setSize:void 0,"data-file-tree-sticky-path":M?Z:void 0,"data-file-tree-sticky-row":M?"true":void 0,"data-item-context-menu-button-visibility":$.actionLaneEnabled?$.contextMenuButtonVisibility:void 0,"data-item-context-menu-trigger-mode":$.contextMenuEnabled?$.contextMenuTriggerMode:void 0,"data-item-has-context-menu-action-lane":$.actionLaneEnabled?"true":void 0,"data-item-has-git-lane":$.gitLaneActive?"true":void 0,"data-item-parent-path":U.length>0?U:void 0,"data-item-parked":q?"true":void 0,"data-item-path":Z,"data-item-type":Q.kind==="directory"?"folder":"file","data-type":"item",id:!M?W:void 0,role:!M?"treeitem":void 0,style:{minHeight:`${G}px`,...K},tabIndex:!M&&Q.isFocused?0:-1,...j}}function C8(J){let{event:Q,mode:X,isSearchOpen:Z,isDirectory:Y}=J,W=Q.ctrlKey||Q.metaKey,q=Q.shiftKey||W,G=Q.shiftKey?{additive:W,kind:"range"}:W?{kind:"toggle"}:{kind:"single"};return{closeSearch:Z,revealCanonical:X==="sticky",selection:G,toggleDirectory:!q&&Y}}var o1,t,F5,b8,H5=Object.is,D3=0,x8=[],Z0=I,w8=Z0.__b,N8=Z0.__r,y8=Z0.diffed,v8=Z0.__c,S8=Z0.unmount,f8=Z0.__;function _4(J,Q){Z0.__h&&Z0.__h(t,J,D3||Q),D3=0;var X=t.__H||(t.__H={__:[],__h:[]});return J>=X.__.length&&X.__.push({}),X.__[J]}function m0(J){return D3=1,QX(g8,J)}function QX(J,Q,X){var Z=_4(o1++,2);if(Z.t=J,!Z.__c&&(Z.__=[X?X(Q):g8(void 0,Q),function(G){var $=Z.__N?Z.__N[0]:Z.__[0],A=Z.t($,G);H5($,A)||(Z.__N=[A,Z.__[1]],Z.__c.setState({}))}],Z.__c=t,!t.__f)){var Y=function(G,$,A){if(!Z.__c.__H)return!0;var K=Z.__c.__H.__.filter(function(U){return!!U.__c});if(K.every(function(U){return!U.__N}))return!W||W.call(this,G,$,A);var M=Z.__c.props!==G;return K.forEach(function(U){if(U.__N){var j=U.__[0];U.__=U.__N,U.__N=void 0,H5(j,U.__[0])||(M=!0)}}),W&&W.call(this,G,$,A)||M};t.__f=!0;var{shouldComponentUpdate:W,componentWillUpdate:q}=t;t.componentWillUpdate=function(G,$,A){if(4&this.__g){var K=W;W=void 0,Y(G,$,A),W=K}q&&q.call(this,G,$,A)},t.shouldComponentUpdate=Y}return Z.__N||Z.__}function V5(J,Q){var X=_4(o1++,3);!Z0.__s&&R5(X.__H,Q)&&(X.__=J,X.u=Q,t.__H.__h.push(X))}function D0(J,Q){var X=_4(o1++,4);!Z0.__s&&R5(X.__H,Q)&&(X.__=J,X.u=Q,t.__h.push(X))}function f(J){return D3=5,e0(function(){return{current:J}},[])}function e0(J,Q){var X=_4(o1++,7);return R5(X.__H,Q)&&(X.__=J(),X.__H=Q,X.__h=J),X.__}function O0(J,Q){return D3=8,e0(function(){return J},Q)}function XX(){for(var J;J=x8.shift();)if(J.__P&&J.__H)try{J.__H.__h.forEach(M4),J.__H.__h.forEach(k5),J.__H.__h=[]}catch(Q){J.__H.__h=[],Z0.__e(Q,J.__v)}}Z0.__b=function(J){t=null,w8&&w8(J)},Z0.__=function(J,Q){J&&Q.__k&&Q.__k.__m&&(J.__m=Q.__k.__m),f8&&f8(J,Q)},Z0.__r=function(J){N8&&N8(J),o1=0;var Q=(t=J.__c).__H;Q&&(F5===t?(Q.__h=[],t.__h=[],Q.__.forEach(function(X){X.__N&&(X.__=X.__N),X.u=X.__N=void 0})):(Q.__h.forEach(M4),Q.__h.forEach(k5),Q.__h=[],o1=0)),F5=t},Z0.diffed=function(J){y8&&y8(J);var Q=J.__c;Q&&Q.__H&&(Q.__H.__h.length&&(x8.push(Q)!==1&&b8===Z0.requestAnimationFrame||((b8=Z0.requestAnimationFrame)||ZX)(XX)),Q.__H.__.forEach(function(X){X.u&&(X.__H=X.u),X.u=void 0})),F5=t=null},Z0.__c=function(J,Q){Q.some(function(X){try{X.__h.forEach(M4),X.__h=X.__h.filter(function(Z){return!Z.__||k5(Z)})}catch(Z){Q.some(function(Y){Y.__h&&(Y.__h=[])}),Q=[],Z0.__e(Z,X.__v)}}),v8&&v8(J,Q)},Z0.unmount=function(J){S8&&S8(J);var Q,X=J.__c;X&&X.__H&&(X.__H.__.forEach(function(Z){try{M4(Z)}catch(Y){Q=Y}}),X.__H=void 0,Q&&Z0.__e(Q,X.__v))};var P8=typeof requestAnimationFrame=="function";function ZX(J){var Q,X=function(){clearTimeout(Z),P8&&cancelAnimationFrame(Q),setTimeout(J)},Z=setTimeout(X,35);P8&&(Q=requestAnimationFrame(X))}function M4(J){var Q=t,X=J.__c;typeof X=="function"&&(J.__c=void 0,X()),t=Q}function k5(J){var Q=t;J.__c=J.__(),t=Q}function R5(J,Q){return!J||J.length!==Q.length||Q.some(function(X,Z){return!H5(X,J[Z])})}function g8(J,Q){return typeof Q=="function"?Q(J):Q}function YX(J,Q=null,X=null){let Z=J.flattenedSegments;if(Z==null||Z.length===0)return Q??J.name;return V("span",{"data-item-flattened-subitems":!0,children:Z.map((Y,W)=>{let q=W===Z.length-1;return V(l0,{children:[V("span",{"data-item-flattened-subitem":Y.path,"data-item-flattened-subitem-drag-target":X===Y.path?"true":void 0,children:q&&Q!=null?Q:V(R3,{children:Y.name})}),W<Z.length-1?" / ":""]},Y.path)})})}function a1(J){return J.isFlattened?J.flattenedSegments?.findLast((Q)=>Q.isTerminal)?.path??J.path:J.path}function D5(J){let Q=J.flattenedSegments;if(Q==null||Q.length===0)return J.name;return Q.map((X)=>X.name).join(" / ")}function m8(J,Q,X,Z){return J.map((Y,W)=>{let q=W*X,G=Y.subtreeEndIndex+1;if(G>=Z)return{row:Y.row,top:q};let $=G*X-Q;return{row:Y.row,top:Math.min(q,$-X)}}).filter((Y)=>Y.top+X>0)}function E5({controller:J,itemHeight:Q,overscan:X,scrollTop:Z,stickyFolders:Y,viewportHeight:W}){let q=J.getVisibleCount(),G=Y&&q>0?J.getStickyRowCandidates(Z,Q):[],$=G==null&&Y&&q>0?J.getVisibleRows(0,q-1):[],A=O8($,{itemHeight:Q,overscan:X,scrollTop:Z,stickyRows:G==null?void 0:m8(G,Z,Q,q),totalRowCount:q,viewportHeight:W}),K=Y&&Z<=0&&q>0?J.getStickyRowCandidates(1,Q):[],M=K!=null&&Z<=0?m8(K,1,Q,q):Y&&Z<=0&&$.length>0?_5($,1,Q):A.sticky.rows;return{overlayHeight:M.reduce((U,j)=>Math.max(U,j.top+Q),0),overlayRows:M,snapshot:A,visibleRows:$}}var WX=400,I8=10,r1=40,u8=18;function qX(J,Q,X){let Z=J,Y=document.elementFromPoint?.bind(document)??null,W=Z.elementFromPoint?.(Q,X)??Y?.(Q,X)??null;if(J instanceof ShadowRoot&&(W==null||!J.contains(W)))return GX(J,Q,X);return W instanceof HTMLElement?W:null}function GX(J,Q,X){let Z=Array.from(J.querySelectorAll('[data-type="item"], [data-item-flattened-subitem]'));for(let Y=Z.length-1;Y>=0;Y--){let W=Z[Y],q=W.getBoundingClientRect();if(Q>=q.left&&Q<=q.right&&X>=q.top&&X<=q.bottom)return W}return null}function c8(J){let Q=J?.closest?.('[data-type="item"]');if(!(Q instanceof HTMLElement))return null;let X=Q.dataset.itemPath??null;if(X==null)return null;let Z=J?.closest?.("[data-item-flattened-subitem]"),Y=Z instanceof HTMLElement?Z.getAttribute("data-item-flattened-subitem")??null:null;if(Y!=null&&Y.endsWith("/"))return{directoryPath:Y,flattenedSegmentPath:Y,hoveredPath:X,kind:"directory"};if(Q.dataset.itemType==="folder")return{directoryPath:X,flattenedSegmentPath:null,hoveredPath:X,kind:"directory"};let W=Q.dataset.itemParentPath??null;if(W==null||W.length===0)return{directoryPath:null,flattenedSegmentPath:null,hoveredPath:X,kind:"root"};return{directoryPath:W,flattenedSegmentPath:null,hoveredPath:X,kind:"directory"}}function p8(J){let Q=J.cloneNode(!0);return Q.removeAttribute("id"),Q.dataset.fileTreeDragPreview="true",Q.setAttribute("aria-hidden","true"),Q.tabIndex=-1,Object.assign(Q.style,{boxShadow:"0 4px 12px rgba(0, 0, 0, 0.15)",left:"0px",margin:"0",pointerEvents:"none",position:"fixed",top:"0px",willChange:"transform",zIndex:"10000"}),Q}function $X(){return navigator.vendor!=="Apple Computer, Inc."}function UX(J,Q){let X=J-Q.top;if(X<r1){let Y=Math.max(0,X);return-Math.ceil((r1-Y)/r1*u8)}let Z=Q.bottom-J;if(Z<r1){let Y=Math.max(0,Z);return Math.ceil((r1-Y)/r1*u8)}return 0}function zX(J,Q){if(J!=null){let X=L8[J];if(X==null)return null;return{text:X,title:B8[J]}}if(Q)return{icon:{name:"file-tree-icon-dot",width:6,height:6},title:F8};return null}function KX(J,Q,X){if(Q==null||Q.size===0)return null;let Z=[];for(let Y=J.length-1;Y>=0;Y-=1){let W=J[Y],q=X.get(W);if(q!=null){for(let G of Z)X.set(G,q);return q?"ignored":null}if(Q.has(W)){X.set(W,!0);for(let G of Z)X.set(G,!0);return"ignored"}Z.push(W)}for(let Y of Z)X.set(Y,!1);return null}function h8(J){return J!=null&&"toggle"in J}function n8(J){return J.code==="Space"||J.key===" "||J.key==="Spacebar"}function AX(J){return J.key.length===1&&/^[\p{L}\p{N}]$/u.test(J.key)&&!J.ctrlKey&&!J.metaKey&&!J.altKey}function MX(J){if(J==null)return"";return`[data-item-section="spacing-item"][data-ancestor-path="${J.replaceAll("\\","\\\\").replaceAll('"',"\\\"")}"] { opacity: 1; }`}function t8(J){return J.shiftKey&&J.key==="F10"||J.key==="ContextMenu"}function _X(J,Q){if(Q&&t8(J))return!0;if((J.ctrlKey||J.metaKey)&&n8(J))return!0;return J.key==="ArrowDown"||J.key==="ArrowLeft"||J.key==="ArrowRight"||J.key==="ArrowUp"}var jX=new Set(["ArrowDown","ArrowLeft","ArrowRight","ArrowUp","End","Home","PageDown","PageUp"]);function l8(J){for(let Q of J.composedPath()){if(!(Q instanceof HTMLElement))continue;if(Q.dataset.fileTreeContextMenuRoot==="true")return!0;if(Q.dataset.type==="context-menu-anchor"||Q.dataset.type===a3)return!0;if(Q.getAttribute("slot")===u1)return!0}return!1}function OX(J){return{bottom:J.bottom,height:J.height,left:J.left,right:J.right,top:J.top,width:J.width,x:J.x,y:J.y}}function LX(J,Q){return{bottom:Q,height:0,left:J,right:J,top:Q,width:0,x:J,y:Q}}function BX(J,Q){if(J==null)return Q.offsetTop;let X=Q.getBoundingClientRect(),Z=J.getBoundingClientRect();return X.top-Z.top}function d8(J,Q,X){if(X==null){J.delete(Q);return}J.set(Q,X)}function i8(J,Q,X){if(J==null)return null;let Z=Q.get(J)??null;if(Z!=null)return Z;let Y=X.get(J)??null;return Y?.dataset.itemParked==="true"?null:Y}function FX(J){if(J==null)return[];let Q=[];for(let X of J.querySelectorAll('button[data-file-tree-sticky-row="true"]')){if(!(X instanceof HTMLElement))continue;let Z=X.dataset.fileTreeStickyPath;if(Z!=null)Q.push(Z)}return Q}function HX(J,Q){if(J==null||Q==null)return null;for(let X of J.querySelectorAll('button[data-item-focused="true"][data-item-parked="true"]'))if(X instanceof HTMLElement&&X.dataset.itemPath===Q)return X;return null}function kX(J,Q,X,Z,Y,W,q){let G=Math.max(0,W-Y),$=Q?.getBoundingClientRect()??null,A=$==null||X==null?null:X.getBoundingClientRect().top-$.top,K=HX(J,Z),M=$==null||K==null?null:K.getBoundingClientRect().top-$.top;return Math.max(0,Math.min(M??Math.max(A??0,G),Math.max(0,q-Y)))}function s8(J,Q){return{kind:J.kind,name:D5(J),path:Q}}function VX(J){return J==null?void 0:`${J}__tree`}function e8(J,Q,X){if(J==null)return;return`${J}__focused-item-${encodeURIComponent(Q)}${X?"__parked":""}`}function o8(J){return J==="file-tree-icon-chevron"||J==="file-tree-icon-dot"||J==="file-tree-icon-file"||J==="file-tree-icon-lock"}function r8(J,Q){if(J==null)return null;if("text"in J)return V("span",{title:J.title,children:J.text});let X=typeof J.icon==="string"?o8(J.icon)?Q(J.icon):{name:J.icon}:o8(J.icon.name)?(()=>{let Z=Q(J.icon.name),{name:Y,...W}=J.icon;return{...Z,...W}})():J.icon;return V("span",{title:J.title,children:V(d1,{...X})})}function a8(J){if(J==null)return;E1(J.querySelector(["button:not([disabled])","[href]","input:not([disabled])","select:not([disabled])","textarea:not([disabled])",'[tabindex]:not([tabindex="-1"])'].join(", "))??J)}function RX(J,Q,{actionLaneEnabled:X=!1,customDecoration:Z=null,decorationLaneEnabled:Y=!1,dragTargetFlattenedSegmentPath:W=null,gitDecoration:q=null,gitLaneActive:G=!1,renameInput:$=null,showDecorativeActionAffordance:A=!1}={}){let K=a1(J);return V(l0,{children:[J.depth>0?V("div",{"data-item-section":"spacing",children:Array.from({length:J.depth}).map((M,U)=>V("div",{"data-item-section":"spacing-item","data-ancestor-path":J.ancestorPaths[U]},U))}):null,V("div",{"data-item-section":"icon",children:J.kind==="directory"?V(d1,{...Q("file-tree-icon-chevron")}):V(d1,{...Q("file-tree-icon-file",K)})}),V("div",{"data-item-section":"content",children:J.isFlattened?YX(J,$,W):$??V(M8,{minimumLength:5,split:"extension",children:J.name})}),Y?V("div",{"data-item-section":"decoration",children:Z!=null?r8(Z,Q):null}):null,G?V("div",{"data-item-section":"git",children:r8(q,Q)}):null,X?V("div",{"data-item-section":"action",children:A?V("span",{"aria-hidden":"true","data-item-action-affordance":"decorative",children:V(d1,{...Q("file-tree-icon-ellipsis")})}):null}):null]})}function j4(J,Q,X,Z={}){let{controller:Y,renameView:W,visualFocusPath:q,contextHoverPath:G,draggedPathSet:$,dragTarget:A,dragAndDropEnabled:K,shouldSuppressContextMenu:M,handleRowDragStart:U,handleRowDragEnd:j,handleRowTouchStart:_,instanceId:F,itemHeight:k,gitStatusByPath:b,ignoredGitDirectories:E,ignoredInheritanceCache:L,directoriesWithGitChanges:B,gitLaneActive:H,contextMenuEnabled:w,contextMenuTriggerMode:P,contextMenuButtonTriggerEnabled:U0,contextMenuButtonVisibility:o,contextMenuRightClickEnabled:_0,registerRenameInput:a,registerButton:e,resolveIcon:$0,renderDecorationForRow:J0,openContextMenuForRow:S0,onRowClick:d,onKeyDown:Y0}=J,Q0=a1(Q),{isParked:T0=!1,mode:d0="flow",style:z1}=Z,i0=d0==="sticky",K1=b?.get(Q0)??null??KX(Q.ancestorPaths,E,L),D1=Q.kind==="directory"&&(B?.has(Q0)??!1),s0=J0(Q,Q0),J1=zX(K1,D1),N0=w&&U0,I0=s0!=null||H||N0,n1=N0&&o==="always",H0=W.getPath()===Q0,A1=H0?W.getValue():"",f0=i0||!H0?null:V(D8,{ref:a,ariaLabel:`Rename ${D5(Q)}`,isFlattened:Q.isFlattened,value:A1,onBlur:()=>{W.commit()},onInput:(W0)=>{W.setValue(W0.currentTarget.value)}}),C3=RX(Q,$0,{actionLaneEnabled:N0,customDecoration:s0,decorationLaneEnabled:I0,dragTargetFlattenedSegmentPath:A?.flattenedSegmentPath??null,gitDecoration:J1,gitLaneActive:H,renameInput:f0,showDecorativeActionAffordance:n1}),o0={...T8({ariaLabel:D5(Q),domId:Q.isFocused?e8(F,Q0,T0):void 0,extraStyle:z1,features:{actionLaneEnabled:N0,contextMenuButtonVisibility:N0?o:null,contextMenuEnabled:w,contextMenuTriggerMode:w?P:null,gitLaneActive:H},isParked:T0,itemHeight:k,mode:d0,row:Q,state:{containsGitChange:D1,effectiveGitStatus:K1,isContextHovered:G===Q0,isDragTarget:A?.kind==="directory"&&A.directoryPath===Q0,isDragging:$?.has(Q0)===!0,isFocusRinged:Q.isFocused&&q===Q0},targetPath:Q0}),key:X,onContextMenu:w||K?(W0)=>{if(M()){W0.preventDefault();return}if(!w)return;if(W0.preventDefault(),!_0)return;Y.focusMountedPathFromInput(Q0),S0(Q,Q0,{anchorRect:LX(W0.clientX,W0.clientY),source:"right-click"})}:void 0,onFocus:!i0?()=>{Y.focusMountedPathFromInput(Q0)}:void 0,onKeyDown:!i0?Y0:void 0,ref:(W0)=>{e(Q0,W0)}};if(!i0&&H0)return V("div",{...o0,children:C3});return V("button",{...o0,type:"button",draggable:K&&!T0,onDragEnd:K&&!T0?j:void 0,onDragStart:K&&!T0?(W0)=>{U(W0,Q,Q0)}:void 0,onMouseDown:(W0)=>{if(i0){W0.preventDefault();return}if(Y.isSearchOpen())W0.preventDefault()},onTouchStart:K&&!T0?(W0)=>{_(W0,Q,Q0)}:void 0,onClick:(W0)=>{d(W0,Q,Q0,d0)},children:C3})}function EX(J,Q,X){if(Q.end<Q.start)return[];return J.controller.getVisibleRows(Q.start,Q.end).filter((Z)=>!X.has(a1(Z))).map((Z,Y)=>j4(J,Z,Q.start+Y))}function T5({composition:J,controller:Q,gitStatusByPath:X,ignoredGitDirectories:Z,directoriesWithGitChanges:Y,icons:W,instanceId:q,itemHeight:G=t3,overscan:$=v7,renamingEnabled:A=!1,renderRowDecoration:K,searchBlurBehavior:M="close",searchEnabled:U=!1,searchFakeFocus:j=!1,slotHost:_,stickyFolders:F=!1,initialViewportHeight:k=e3}){let b=f(null),E=f(null),L=f(!1),B=f(null),H=f(null),w=f(null),P=f(null),U0=f(null),o=f(new Map),_0=f(new Map),a=f(()=>{}),e=f(null),$0=f(0),J0=f(!1),S0=f(null);if(S0.current!==Q)J0.current=!1,S0.current=Q;let d=f(!1),Y0=f(null),Q0=f(null),T0=f(!1),d0=f(null),z1=f(null),i0=f(null),K1=f(null),D1=f(null),s0=f(null),J1=f(null),N0=f(null),I0=f(!1),n1=f(null),H0=f(null),A1=f(null),f0=f(null),C3=e0(()=>new Map,[]),[,o0]=m0(0),[W0,Q1]=m0(null),[O4,b3]=m0(null),[L4,$9]=m0(null),[U9,M1]=m0(null),[z9,K9]=m0(0),[c,B4]=m0(null),t1=f(c);t1.current=c;let w3=f(null),e1=f(null),J3=f(null),Q3=f(null),b5=f(null),N3=f(!1),A9=()=>{e1.current=null,J3.current=null,Q3.current=null},F4=(z,O)=>{e1.current=z,J3.current=null,Q3.current=O==null?null:{path:z,scrollTop:O}},M9=(z,O)=>{e1.current=null,J3.current={path:z,viewportOffset:O},Q3.current=null},w5=f(M==="retain"&&Q.isSearchOpen()),[_9,N5]=m0(j);V5(()=>{if(!j)N5(!1)},[j]);let y5=f(!1),H4=O0(()=>{y5.current=!0,N5((z)=>z?!1:z)},[]),[j9,O9]=m0(()=>E5({controller:Q,itemHeight:G,overscan:$,scrollTop:0,stickyFolders:F,viewportHeight:k})),[L9,B9]=m0(!1);V5(()=>{B9(!0)},[]);let k0=J?.contextMenu?.enabled===!0||J?.contextMenu?.render!=null||J?.contextMenu?.onOpen!=null||J?.contextMenu?.onClose!=null,T1=J?.contextMenu?.triggerMode??(k0?"right-click":"both"),C1=T1==="both"||T1==="button",v5=J?.contextMenu?.buttonVisibility??"when-needed",F9=T1==="both"||T1==="right-click";D0(()=>{let z=w.current;if(z==null)return;let O=(R)=>{if(!(R instanceof CustomEvent))return;let D=R.detail?.path??null;b5.current=D,b3(D),M1(D==null?null:"pointer")},y=(R)=>{if(!(R instanceof CustomEvent))return;N3.current=R.detail?.disabled===!0};return z.addEventListener("file-tree-debug-set-context-menu-trigger",O),z.addEventListener("file-tree-debug-set-scroll-suppression",y),()=>{z.removeEventListener("file-tree-debug-set-context-menu-trigger",O),z.removeEventListener("file-tree-debug-set-scroll-suppression",y)}},[]);let H9=O0((z,O)=>{d8(o.current,z,O)},[]),k9=O0((z,O)=>{d8(_0.current,z,O)},[]),V9=O0((z)=>{H.current=z},[]),X3=O0((z)=>{return i8(z,_0.current,o.current)},[]),S5=X!=null||Z!=null||Y!=null,{resolveIcon:f5}=e0(()=>r7(W),[W]),Z3=Q[Q5](),b1=Z3.getPath(),k4=b1!=null,u0=Q.isSearchOpen(),R9=Q.getSearchValue(),x=Q.getFocusedPath(),p=Q.getFocusedIndex(),_1=Q.getScrollRequest(),r0=Q.isDragAndDropEnabled(),Y3=Q.getDragSession(),E9=e0(()=>Y3==null?null:new Set(Y3.draggedPaths),[Y3]),D9=Y3?.target??null,W3=Y3?.primaryPath??null,P5=VX(q),{overlayHeight:T9,overlayRows:C9,snapshot:z0,visibleRows:y3}=j9,j0=z0.physical.viewportHeight,P0=e0(()=>({end:z0.window.endIndex,start:z0.window.startIndex}),[z0.window.endIndex,z0.window.startIndex]),q3=C9,x5=z0.sticky.rows,j1=z0.physical.totalHeight,w1=z0.sticky.height,v3=e0(()=>new Set(x5.map((z)=>a1(z.row))),[x5]),V4=p>=0&&p>=P0.start&&p<=P0.end,b9=O0((z,O)=>K?.({item:s8(z,O),row:z})??null,[K]),g5=O0((z)=>{if(E1(z==null?null:o.current.get(z)??null))return!0;return E1(w.current)},[]),S3=O0((z)=>{g5(Q.focusNearestPath(z))},[Q,g5]),m5=f(S3);m5.current=S3;let N1=f(!0),R4=f(()=>{}),y0=O0((z=!0)=>{let O=t1.current;if(O==null)return;if(N1.current=N1.current&&z,B4(null),J?.contextMenu?.onClose?.(),N1.current)S3(O.path)},[J?.contextMenu,S3]);R4.current=y0;let G3=O0((z)=>{let O=z==null?null:BX(w.current,z);$9((y)=>y===O?y:O)},[]),I5=O0((z,O,y)=>{let R=Q.getItem(O);if(R==null)return;let D=X3(O);if(D?.dataset.fileTreeStickyRow==="true"){let v=P.current;F4(O,v?.scrollTop??null),d.current=!0,Q1((r)=>r===O?r:O)}R.focus(),G3(D),N1.current=!0,B4({anchorRect:y?.anchorRect??null,item:s8(z,O),path:O,source:y?.source??"keyboard"})},[Q,X3,G3]),w9=O0((z)=>{if(!A)return;if(Q.isSearchOpen()){let O=P.current,y=i1(O,j0);d0.current=p<0||O==null?null:Math.max(0,Math.min(p*G-O.scrollTop,Math.max(0,y-G))),T0.current=!0}if(Q.startRenaming(z)===!1)return;M1("focus"),o0((O)=>O+1)},[Q,p,G,A,j0]),f3=O0((z,{restoreTreeFocus:O=!0,targetOffset:y="live-overlay"}={})=>{let R=P.current;if(R==null)return!1;Q.focusPath(z);let D=Q.getFocusedIndex();if(D<0)return!1;let v=Q.getVisibleRows(D,D)[0]??null;if(v==null)return!1;let r=i1(R,j0),S=Q.getVisibleCount()*G,m=y==="sticky-parents"?v.ancestorPaths.length*G:E5({controller:Q,itemHeight:G,overscan:$,scrollTop:R.scrollTop,stickyFolders:F,viewportHeight:r}).snapshot.sticky.height;return d.current=!0,s1(R,D,G,r,S,m),a.current(),w3.current=O?z:null,!0},[Q,G,$,j0,F]),N9=()=>{return L.current===!0||f0.current!=null||I0.current===!0},u5=(z)=>{return typeof window.requestAnimationFrame==="function"?window.requestAnimationFrame(()=>{z()}):window.setTimeout(z,16)},y9=(z)=>{if(z==null)return;if(typeof window.cancelAnimationFrame==="function"){window.cancelAnimationFrame(z);return}window.clearTimeout(z)},X1=()=>{if(K1.current!=null)clearTimeout(K1.current),K1.current=null;i0.current=null},P3=()=>{s0.current?.remove(),s0.current=null},$3=()=>{y9(z1.current),z1.current=null,D1.current=null},c5=(z)=>{let O=w.current?.getRootNode();if(O instanceof ShadowRoot){O.append(z);return}document.body.append(z)},U3=()=>{if(N0.current?.(),N0.current=null,f0.current!=null)clearTimeout(f0.current),f0.current=null;if(I0.current=!1,n1.current=null,A1.current=null,H0.current!=null)H0.current.setAttribute("draggable","true"),H0.current.style.removeProperty("touch-action"),H0.current=null;P3(),X1(),$3(),J1.current=null},x3=(z,O)=>{let y=w.current?.getRootNode(),R=c8(qX(y instanceof ShadowRoot?y:document,z,O));return Q.setDragTarget(R),Q.getDragSession()?.target??null},E4=(z)=>{let O=Q.getDragAndDropConfig()?.openOnDropDelay??800;if(z==null||z.kind!=="directory"||z.directoryPath==null||O<=0){X1();return}let y=Q.getItem(z.directoryPath),R=h8(y)?y:null;if(R==null||R.isExpanded()){X1();return}let D=`${z.directoryPath}::${z.flattenedSegmentPath??""}`;if(i0.current===D)return;X1(),i0.current=D,K1.current=setTimeout(()=>{let v=Q.getDragSession()?.target;if(v?.kind!=="directory"||v.directoryPath!==z.directoryPath||v.flattenedSegmentPath!==z.flattenedSegmentPath)return;R.expand()},O)},p5=()=>{z1.current=null;let z=D1.current,O=P.current;if(z==null||O==null||Q.getDragSession()==null)return;let y=O.getBoundingClientRect(),R=UX(z.clientY,y);if(R===0)return;let D=Math.max(0,O.scrollHeight-O.clientHeight),v=Math.max(0,Math.min(D,O.scrollTop+R));if(v!==O.scrollTop)O.scrollTop=v,a.current();E4(x3(z.clientX,z.clientY)),z1.current=u5(p5)},h5=(z,O)=>{D1.current={clientX:z,clientY:O},z1.current??=u5(p5)},v9=(z,O,y)=>{let R=z.currentTarget;if(R==null)return;if(U3(),P3(),X1(),$3(),Q.startDrag(y)===!1){z.preventDefault();return}if(J1.current=O,z.dataTransfer!=null){if(z.dataTransfer.effectAllowed="move",z.dataTransfer.dropEffect="move",z.dataTransfer.setData("text/plain",y),$X()){let D=p8(R),v=R.getBoundingClientRect();Object.assign(D.style,{height:`${v.height}px`,opacity:"0.85",transform:"translate3d(-9999px, 0px, 0)",width:`${v.width}px`}),c5(D),s0.current=D,z.dataTransfer.setDragImage(D,Math.max(0,z.clientX-v.left),Math.max(0,z.clientY-v.top))}}},S9=()=>{P3(),X1(),$3(),J1.current=null,Q.cancelDrag()},f9=(z,O,y)=>{if(f0.current!=null||I0.current)return;let R=z.touches[0],D=z.currentTarget;if(R==null||D==null)return;A1.current={clientX:R.clientX,clientY:R.clientY},H0.current=D,D.setAttribute("draggable","false");let v=(m={})=>{let h=m.restoreNativeDraggable??!I0.current;if(f0.current!=null)clearTimeout(f0.current),f0.current=null;if(document.removeEventListener("touchmove",r),document.removeEventListener("touchend",S),document.removeEventListener("touchcancel",S),N0.current===v)N0.current=null;if(h){if(D.setAttribute("draggable","true"),H0.current===D)H0.current=null;A1.current=null}},r=(m)=>{let h=m.touches[0],i=A1.current;if(h==null||i==null)return;let X0=h.clientX-i.clientX,q0=h.clientY-i.clientY;if(X0*X0+q0*q0<=I8*I8)return;v()},S=()=>{v()};document.addEventListener("touchmove",r,{passive:!0}),document.addEventListener("touchend",S),document.addEventListener("touchcancel",S),N0.current=v,f0.current=setTimeout(()=>{if(v({restoreNativeDraggable:!1}),Q.startDrag(y)===!1){if(D.setAttribute("draggable","true"),H0.current===D)H0.current=null;A1.current=null;return}I0.current=!0,H0.current=D,D.setAttribute("draggable","false"),D.style.setProperty("touch-action","none"),J1.current=O;let m=D.getBoundingClientRect(),h=p8(D);Object.assign(h.style,{height:`${m.height}px`,opacity:"0.85",transform:`translate3d(${m.left}px, ${m.top}px, 0)`,width:`${m.width}px`}),c5(h),s0.current=h,n1.current={x:R.clientX-m.left,y:R.clientY-m.top};let i=(c0)=>{let G0=c0.touches[0];if(G0==null)return;c0.preventDefault();let C0=n1.current;if(C0!=null&&s0.current!=null)s0.current.style.transform=`translate3d(${G0.clientX-C0.x}px, ${G0.clientY-C0.y}px, 0)`;E4(x3(G0.clientX,G0.clientY)),h5(G0.clientX,G0.clientY)},X0=(c0)=>{let G0=c0.changedTouches[0];if(G0!=null)x3(G0.clientX,G0.clientY);Q.completeDrag(),U3()},q0=()=>{Q.cancelDrag(),U3()};N0.current=()=>{document.removeEventListener("touchmove",i),document.removeEventListener("touchend",X0),document.removeEventListener("touchcancel",q0)},document.addEventListener("touchmove",i,{passive:!1}),document.addEventListener("touchend",X0),document.addEventListener("touchcancel",q0)},WX)},l5=(z)=>{if(c!=null){if(z.key==="Escape"){y0(),z.preventDefault(),z.stopPropagation();return}if(jX.has(z.key))z.preventDefault(),z.stopPropagation();return}if(Z3.isActive()){if(z.key==="Escape")Z3.cancel();else if(z.key==="Enter")Z3.commit();else return;M1("focus"),o0((n)=>n+1),z.preventDefault(),z.stopPropagation();return}if(A&&z.key==="F2"){w9(x??void 0),z.preventDefault(),z.stopPropagation();return}if(u0){if(z.key==="Escape")T0.current=!1,d0.current=null,Q.closeSearch();else if(z.key==="Enter"){let n=Q.getFocusedPath();if(n!=null)Q.selectOnlyPath(n);let p0=P.current,u3=i1(p0,j0);d0.current=p<0||p0==null?null:Math.max(0,Math.min(p*G-p0.scrollTop,Math.max(0,u3-G))),T0.current=!0,Q.closeSearch()}else if(z.key==="ArrowDown")Q.focusNextSearchMatch();else if(z.key==="ArrowUp")Q.focusPreviousSearchMatch();else return;M1("focus"),o0((n)=>n+1),z.preventDefault(),z.stopPropagation();return}if(U&&AX(z)){Q.openSearch(z.key),o0((n)=>n+1),z.preventDefault(),z.stopPropagation();return}let O=k0&&t8(z),y=_X(z,k0),R=y&&w.current!=null?E3(w.current):null,D=y?new Set(FX(w.current)):new Set,v=R?.dataset.fileTreeStickyPath??null,r=R?.dataset.fileTreeStickyRow==="true"&&v!=null;if(r&&v!==x&&D.has(v)){let n=P.current;F4(v,n?.scrollTop??null),Q.focusPath(v)}let S=Q.getFocusedPath(),m=Q.getFocusedIndex(),h=Q.getFocusedItem();if(h==null)return;let i=h8(h)?h:null,X0=S!=null&&(v3.has(S)||r&&v===S&&D.has(S)),q0=z.key==="ArrowDown"||z.key==="ArrowUp"||z.key==="ArrowRight"&&i!=null&&i.isExpanded(),c0=z.key==="ArrowLeft"&&X0&&i!=null&&i.isExpanded(),G0=P.current,C0=!0;if(z.shiftKey&&z.key==="ArrowDown")Q.extendSelectionFromFocused(1);else if(z.shiftKey&&z.key==="ArrowUp")Q.extendSelectionFromFocused(-1);else if(O&&S!=null&&m>=0){let n=Q.getVisibleRows(m,m)[0]??null,p0=i8(S,_0.current,o.current);if(n==null||p0==null)C0=!1;else I5(n,S)}else if((z.ctrlKey||z.metaKey)&&n8(z))Q.toggleFocusedSelection();else if((z.ctrlKey||z.metaKey)&&z.key.toLowerCase()==="a")Q.selectAllVisiblePaths();else switch(z.key){case"ArrowDown":Q.focusNextItem();break;case"ArrowUp":Q.focusPreviousItem();break;case"ArrowRight":if(i==null||i.isExpanded())Q.focusNextItem();else i.expand();break;case"ArrowLeft":if(i!=null&&i.isExpanded())i.collapse();else Q.focusParentItem();break;case"Home":Q.focusFirstItem();break;case"End":Q.focusLastItem();break;default:C0=!1}if(!C0)return;M1("focus");let g=Q.getFocusedPath(),V0=g!=null&&(v3.has(g)||D.has(g)),x0=q0&&g!==S,I3=O&&r&&v===S&&g===S;if((X0||I3)&&g!=null&&(x0&&V0||I3))F4(g,G0?.scrollTop??null),d.current=!0,Q1((n)=>n===g?n:g);else{let n=z.key==="ArrowUp"&&X0&&g!==S;if(g!=null&&(n||c0&&g===S))M9(g,kX(w.current,G0,R,S,G,w1,j0)),d.current=!0,Q1((p0)=>p0===g?p0:g);else A9()}o0((n)=>n+1),z.preventDefault(),z.stopPropagation()};D0(()=>{if(!U||!u0)return;if(w5.current){w5.current=!1;return}E1(U0.current)},[u0,U]),D0(()=>{let z=H.current;switch(E8({hasRenderedInput:z!=null,previousRenamingPath:Q0.current,renamingPath:b1})){case"reset":Q0.current=null;return;case"reveal-canonical":if(b1!=null)f3(b1,{restoreTreeFocus:!1,targetOffset:"live-overlay"});return;case"ignore":return;case"focus-input":if(z!=null)w3.current=null,Q0.current=b1,E1(z),z.select();return}},[P0.end,P0.start,b1,f3,v3]),D0(()=>{let z=w.current;if(z==null)return;let O=null,y=()=>{if(O==null)return;clearTimeout(O),O=null},R=()=>{let r=E3(z)?.dataset.itemPath??null;Q1((S)=>S===r?S:r)},D=()=>{y(),d.current=!0,R()},v=(r)=>{let S=r.relatedTarget;if(S==null){y(),O=setTimeout(()=>{if(O=null,E3(z)!=null){R();return}d.current=!1,Q1(null)},0);return}if(!(S instanceof Node)||!z.contains(S)){y(),d.current=!1,Q1(null);return}let m=S instanceof HTMLElement?S.dataset.itemPath??null:null;Q1((h)=>h===m?h:m)};return z.addEventListener("focusin",D),z.addEventListener("focusout",v),()=>{y(),z.removeEventListener("focusin",D),z.removeEventListener("focusout",v)}},[]),D0(()=>{let z=w.current;if(z==null)return;if(z0.physical.scrollTop<=0)z.dataset.scrollAtTop="true";else delete z.dataset.scrollAtTop},[z0.physical.scrollTop]),D0(()=>{let z=null,O=P.current,y=B.current,R=w.current;if(O==null)return;e.current=i1(O,k);let D=()=>{let g=Q.getVisibleCount(),V0=O5(e.current,k),x0=Math.max(0,g*G-V0);if(O.scrollTop>x0)O.scrollTop=x0;O9(E5({controller:Q,itemHeight:G,overscan:$,scrollTop:Math.min(O.scrollTop,x0),stickyFolders:F,viewportHeight:V0}))};if(!J0.current){J0.current=!0;let g=Q.getFocusedIndex();if(g>=0){let V0=O5(e.current,k),x0=Q.getVisibleRows(g,g)[0]??null;L5(O,g,G,V0,F&&x0!=null?Math.max(0,Math.min(x0.ancestorPaths.length*G,Math.max(0,V0-G))):0)}}a.current=D;let v=!1,r=Q.subscribe(()=>{if(v)o0((g)=>g+1);else v=!0;D()}),S=()=>{if(N3.current===!0)return;if(y!=null)y.dataset.isScrolling??="";if(R!=null)R.dataset.isScrolling??="";if(L.current=!0,z!=null)clearTimeout(z);z=setTimeout(()=>{if(y!=null)delete y.dataset.isScrolling;if(R!=null)delete R.dataset.isScrolling;L.current=!1,K9((g)=>g+1),z=null},50)},m=null,h=()=>{if(R!=null)delete R.dataset.overlayReveal;if(m!=null)clearTimeout(m),m=null},i=()=>{if(R==null||N3.current===!0)return;if(O.scrollTop>0)return;if(R.dataset.overlayReveal="true",m!=null)clearTimeout(m);m=setTimeout(()=>{h()},200)},X0=()=>{if(D(),O.scrollTop>0)h();if(t1.current!=null&&L.current)R4.current();if(N3.current===!0){L.current=!1;return}b3((g)=>g==null?g:null),S()},q0=()=>{S(),i()},c0=new Set(["ArrowUp","ArrowDown","ArrowLeft","ArrowRight","PageUp","PageDown","Home","End"," ","Spacebar"]),G0=(g)=>{if(!c0.has(g.key))return;q0()};O.addEventListener("scroll",X0,{passive:!0}),O.addEventListener("wheel",q0,{passive:!0}),O.addEventListener("touchmove",q0,{passive:!0}),O.addEventListener("keydown",G0);let C0=typeof ResizeObserver<"u"?new ResizeObserver((g)=>{e.current=(g[0]==null?null:V8(g[0]))??i1(O,k),D()}):null;return C0?.observe(O),()=>{if(a.current=()=>{},r(),O.removeEventListener("scroll",X0),O.removeEventListener("wheel",q0),O.removeEventListener("touchmove",q0),O.removeEventListener("keydown",G0),z!=null)clearTimeout(z);if(m!=null)clearTimeout(m);if(y!=null)delete y.dataset.isScrolling;if(R!=null)delete R.dataset.isScrolling,delete R.dataset.overlayReveal;L.current=!1,e.current=null,C0?.disconnect()}},[Q,k,G,$,F]),D0(()=>{if(k0||c==null)return;y0(!1)},[y0,k0,c]);let d5=e0(()=>c==null?null:`${c.path}::${c.source}`,[c]);D0(()=>{if(d5==null){_?.clearSlotContent(u1);return}let z=t1.current;if(z==null)return;let O=E.current??b.current;if(O==null)return;let y={anchorElement:O,anchorRect:z.anchorRect??OX(O.getBoundingClientRect()),close:(D)=>{R4.current(D?.restoreFocus??!0)},restoreFocus:()=>{if(!N1.current)return;m5.current(t1.current?.path??null)}},R=J?.contextMenu?.render?.(z.item,y)??null;return _?.setSlotContent(u1,R),J?.contextMenu?.onOpen?.(z.item,y),a8(R),queueMicrotask(()=>{if(R==null||!R.isConnected)return;if(document.activeElement!==R)return;a8(R)}),()=>{_?.clearSlotContent(u1)}},[d5,J?.contextMenu,_]),D0(()=>{if(c!=null&&Q.getItem(c.path)==null)y0()},[y0,c,Q]),D0(()=>{if(c==null)return;let z=w.current?.getRootNode(),O=z instanceof ShadowRoot?z.host:w.current,y=(D)=>{let v=D.target;if(!(v instanceof Node))return;if(l8(D))return;if(b.current?.contains(v)===!0)return;if(O?.contains(v)===!0)return;y0()},R=(D)=>{if(D.key==="Escape")D.preventDefault(),D.stopPropagation(),y0()};return document.addEventListener("mousedown",y,!0),document.addEventListener("keydown",R,!0),()=>{document.removeEventListener("mousedown",y,!0),document.removeEventListener("keydown",R,!0)}},[y0,c]),D0(()=>{let z=P.current,O=w.current;if(z==null||O==null){Y0.current=x;return}let y=x==null?null:o.current.get(x)??null,R=E3(O),D=R?.dataset.itemPath??null,v=k4&&H.current===R,r=U&&U0.current===R,S=T0.current&&!u0,m=d0.current??0,h=w3.current,i=e1.current,X0=J3.current,q0=Q3.current,c0=R!=null,G0=d.current||c0,C0=Y0.current!==x,g=i!=null&&i===x&&x!=null,V0=!1,x0=!1;if(_1!=null&&_1.id!==$0.current){$0.current=_1.id;let T4=_1.visibleIndex,a5=Q.getVisibleRows(T4,T4)[0]??null;if(a5!=null){let qJ=F?Math.max(0,Math.min(a5.ancestorPaths.length*G,Math.max(0,j0-G))):w1;V0=!0,x0=R8(z,T4,G,j0,j1,_1.offset,qJ)}Q.clearScrollRequest(_1.id)}let I3=!V0&&S&&s1(z,p,G,j0,j1,m),n=!V0&&h!=null&&h===x&&s1(z,p,G,j0,j1,w1),p0=!V0&&X0!=null&&X0.path===x&&s1(z,p,G,j0,j1,X0.viewportOffset),u3=!V0&&q0!=null&&q0.path===x&&z.scrollTop!==q0.scrollTop;if(u3)z.scrollTop=q0.scrollTop;if(u3||x0||n||p0||I3||G0&&C0&&h!==x&&!g&&L5(z,p,G,j0,w1))a.current();if(V0){Y0.current=x;return}if(!G0){Y0.current=x;return}if(v){Y0.current=x;return}if(r&&!S){Y0.current=x;return}if(y==null){if(S&&p>=0)s1(z,p,G,j0,j1,m),a.current();Y0.current=x;return}if(C0||S||h===x||i===x||X0?.path===x||q0?.path===x||D==null||D!==x){if(E1(y),h===x)w3.current=null;if(i===x)e1.current=null;if(X0?.path===x)J3.current=null;if(q0?.path===x)Q3.current=null;T0.current=!1,d0.current=null}Y0.current=x},[Q,p,x,V4,G,k4,u0,P0,j0,U,_1,F,w1,j1,y3]);let P9=p>=0&&p>=z0.visible.startIndex&&p<=z0.visible.endIndex,x9=x!=null&&q3.some((z)=>a1(z.row)===x),g9=P9||x9,m9=C1&&d.current===!0&&g9?x:null,I9=U9==="pointer"?O4:null,O1=c?.path??b5.current??I9??m9??O4,i5=c?.source==="right-click";D0(()=>{if(L.current&&c==null)return;G3(X3(O1))},[c,X3,P0,j0,z9,q3,O1,G3,y3]);let u9=O0((z)=>{if(L.current)return;if(l8(z))return;let O=z.target;if(!(O instanceof HTMLElement))return;if(O.closest?.(`[data-type="${a3}"]`)!=null)return;let y=O.closest?.('[data-file-tree-sticky-row="true"]'),R=O.closest?.('[data-type="item"]'),D=y instanceof HTMLElement?y.dataset.fileTreeStickyPath??null:R instanceof HTMLElement?R.dataset.itemPath??null:null;if(D!=null)M1((v)=>v==="pointer"?v:"pointer");b3((v)=>v===D?v:D)},[]),c9=O0(()=>{b3(null)},[]);D0(()=>{if(!r0)return;let z=()=>{U3(),Q.cancelDrag()};return window.addEventListener("dragend",z),()=>{window.removeEventListener("dragend",z),U3(),Q.cancelDrag()}},[Q,r0]);let p9=(z)=>{if(!r0||Q.getDragSession()==null||I0.current)return;let O=c8(z.target instanceof HTMLElement?z.target:null);if(Q.setDragTarget(O),E4(Q.getDragSession()?.target??null),h5(z.clientX,z.clientY),z.dataTransfer!=null)z.dataTransfer.dropEffect="move";z.preventDefault()},h9=(z)=>{if(!r0||Q.getDragSession()==null||I0.current)return;let O=z.relatedTarget;if(O instanceof Node&&w.current?.contains(O)===!0)return;X1(),$3(),Q.setDragTarget(null)},l9=(z)=>{if(!r0||Q.getDragSession()==null||I0.current)return;z.preventDefault(),x3(z.clientX,z.clientY),Q.completeDrag(),P3(),X1(),$3(),J1.current=null},z3=z0.window.height,d9=z0.window.offsetTop,i9=Math.min(0,j0-z3),s9=Math.min(0,j0-z3-w1),o9=W0===x||T0.current,y1=x!=null&&o9&&!V4&&p>=0?y3[p]??Q.getVisibleRows(p,p)[0]??null:null,s5=y1==null?null:B5(p,G,P0,z3),Z1=J1.current,r9=W3!=null&&Z1!=null&&Z1.path===W3&&Z1.index>=P0.start&&Z1.index<=P0.end,K3=W3!=null&&Z1!=null&&Z1.path===W3&&!r9&&Z1.path!==y1?.path?Z1:null,o5=K3==null?null:B5(K3.index,G,P0,z3),a9=MX((p>=0?y3[p]??Q.getVisibleRows(p,p)[0]??null:null)?.ancestorPaths.at(-1)??null),n9=u0&&x!=null?e8(q,x,!V4):void 0,t9=c?.path??(u0?x:W0),e9=c?.path??O4,A3=X3(O1),D4=k0&&C1&&!i5&&!k4&&A3!=null&&L4!=null&&O1!=null,JJ=k0&&(D4||c!=null),g3=c?.anchorRect,r5=g3==null&&A3!=null&&L4!=null&&(c!=null||D4)?L4:null,QJ=g3!=null?{left:`${g3.left}px`,position:"fixed",right:"auto",top:`${g3.top}px`}:r5!=null?{top:`${r5}px`}:void 0,XJ=i5?{opacity:"0"}:void 0,ZJ=O0((z,O,y,R)=>{let D=C8({event:{ctrlKey:z.ctrlKey,metaKey:z.metaKey,shiftKey:z.shiftKey},isDirectory:O.kind==="directory",isSearchOpen:u0,mode:R}),v=D.toggleDirectory&&O.kind==="directory",r=v?Q.resolveMountedDirectoryPathFromInput(y):null;if(v&&r==null)return;let S=r??y;switch(D.selection.kind){case"range":Q.selectPathRange(S,D.selection.additive);break;case"toggle":Q.togglePathSelectionFromInput(S);break;case"single":Q.selectOnlyMountedPathFromInput(S);break}let m=z.currentTarget instanceof HTMLElement?z.currentTarget:null,h=O.index>=z0.visible.startIndex&&O.index<=z0.visible.endIndex,i=R==="flow"&&h&&m!=null&&m.dataset.itemParked!=="true";if(Q.focusMountedPathFromInput(S),i)d.current=!0,Q1((X0)=>X0===S?X0:S),M1("focus");if(v)Q.toggleMountedDirectoryFromInput(S);if(D.closeSearch)Q.closeSearch();if(D.revealCanonical)f3(S,{targetOffset:"sticky-parents"})},[Q,u0,z0.visible.endIndex,z0.visible.startIndex,f3]),YJ=()=>{if(L.current)return;if(!C1)return;if(O1==null||A3==null)return;let z=Q.getItem(O1);if(z==null)return;G3(A3),N1.current=!0,B4({anchorRect:null,item:{kind:z.isDirectory()?"directory":"file",name:A3.getAttribute("aria-label")??O1,path:z.getPath()},path:z.getPath(),source:"button"})},m3={contextHoverPath:e9,contextMenuButtonTriggerEnabled:C1,contextMenuButtonVisibility:v5,contextMenuEnabled:k0,contextMenuRightClickEnabled:F9,contextMenuTriggerMode:T1,controller:Q,directoriesWithGitChanges:Y,dragAndDropEnabled:r0,draggedPathSet:E9,dragTarget:D9,gitLaneActive:S5,gitStatusByPath:X,handleRowDragEnd:S9,handleRowDragStart:v9,handleRowTouchStart:f9,ignoredGitDirectories:Z,ignoredInheritanceCache:C3,instanceId:q,itemHeight:G,onKeyDown:l5,onRowClick:ZJ,openContextMenuForRow:I5,registerButton:H9,registerRenameInput:V9,renameView:Z3,renderDecorationForRow:b9,resolveIcon:f5,shouldSuppressContextMenu:N9,visualFocusPath:t9},WJ={...m3,registerButton:k9};return V("div",{ref:w,id:P5,"data-file-tree-context-menu-button-visibility":k0&&C1?v5:void 0,"data-file-tree-context-menu-trigger-mode":k0?T1:void 0,"data-file-tree-has-context-menu-action-lane":k0&&C1?"true":void 0,"data-file-tree-has-git-lane":S5?"true":void 0,"data-file-tree-virtualized-root":"true",onDragLeave:r0?h9:void 0,onDragOver:r0?p9:void 0,onDrop:r0?l9:void 0,onKeyDown:l5,onPointerLeave:k0?c9:void 0,onPointerOver:k0?u9:void 0,role:"tree",tabIndex:-1,style:{outline:"none",position:"relative"},children:[V("style",{"data-file-tree-guide-style":"true",dangerouslySetInnerHTML:{__html:a9}}),V("slot",{name:H3,"data-type":"header-slot"}),U?V("div",{"data-file-tree-search-container":!0,"data-open":u0?"true":"false",children:V("input",{ref:U0,"aria-activedescendant":n9,"aria-controls":P5,placeholder:"Search…","data-file-tree-search-input":!0,"data-file-tree-search-input-fake-focus":_9?"true":void 0,value:R9,onBlur:()=>{if(M==="retain"&&!y5.current)return;Q.closeSearch()},onFocus:H4,onPointerDown:H4,onInput:(z)=>{H4();let O=z.currentTarget;Q.setSearch(O.value)}})}):null,V("div",{ref:P,"data-file-tree-virtualized-scroll":"true",children:[F&&L9&&q3.length>0?V("div",{"aria-hidden":"true","data-file-tree-sticky-overlay":"true",children:V("div",{"data-file-tree-sticky-overlay-content":"true",style:{height:`${T9}px`},children:q3.map((z,O)=>j4(WJ,z.row,`sticky:${a1(z.row)}`,{mode:"sticky",style:{left:"0",position:"absolute",right:"0",top:`${z.top}px`,zIndex:`${q3.length-O}`}}))})}):null,V("div",{ref:B,"data-file-tree-virtualized-list":"true",style:{height:`${j1}px`},children:[V("div",{"data-file-tree-virtualized-sticky-offset":"true","aria-hidden":"true",style:{height:`${d9}px`}}),V("div",{"data-file-tree-virtualized-sticky":"true",style:{height:`${z3}px`,top:`${i9}px`,bottom:`${s9}px`},children:[EX(m3,P0,v3),y1!=null&&s5!=null?j4(m3,y1,`parked:${y1.path}`,{isParked:!0,style:{left:"0",opacity:"0",pointerEvents:W3===y1.path?"none":void 0,position:"absolute",right:"0",top:`${s5}px`}}):null,K3!=null&&o5!=null?j4(m3,K3,`parked-drag:${K3.path}`,{isParked:!0,style:{left:"0",opacity:"0",pointerEvents:"none",position:"absolute",right:"0",top:`${o5}px`}}):null]})]})]}),k0?V("div",{ref:b,"data-type":"context-menu-anchor","data-visible":JJ?"true":"false",style:QJ,children:[V("button",{ref:E,type:"button","data-type":a3,"aria-label":"Options","aria-haspopup":"menu","aria-expanded":c!=null?"true":"false","data-visible":D4?"true":"false",onMouseDown:(z)=>{z.preventDefault()},onClick:(z)=>{if(z.preventDefault(),z.stopPropagation(),c!=null){y0();return}YJ()},tabIndex:-1,style:XJ,children:V(d1,{...f5("file-tree-icon-ellipsis")})}),c!=null?V("slot",{name:u1}):null]}):null,c!=null?V("div",{"data-type":"context-menu-wash","aria-hidden":"true",onMouseDownCapture:(z)=>{z.preventDefault(),y0()},onTouchStartCapture:(z)=>{z.preventDefault(),z.stopPropagation(),y0()},onTouchMoveCapture:(z)=>{z.preventDefault(),z.stopPropagation()},onWheelCapture:(z)=>{z.preventDefault(),z.stopPropagation()}}):null]})}var C5={hydrateRoot:(J,Q)=>{z8(l1(T5,Q),J)},renderRoot:(J,Q)=>{A4(l1(T5,Q),J)},unmountRoot:(J)=>{A4(null,J)}};function T3(J,Q){C5.renderRoot(J,Q)}function J9(J,Q){C5.hydrateRoot(J,Q)}function Q9(J){C5.unmountRoot(J)}var X9=class{#J=new Map;#X=null;clearAll(){for(let J of this.#J.values())J.remove();this.#J.clear()}clearSlotContent(J){let Q=this.#U(J);if(Q==null)return;Q.remove(),this.#J.delete(J)}setHost(J){if(this.#X=J,J==null)return;this.#q(J);for(let[Q,X]of this.#J)this.#z(Q,X)}setSlotContent(J,Q){let X=this.#U(J);if(X===Q){if(Q!=null)this.#J.set(J,Q),this.#z(J,Q);return}if(X?.remove(),Q==null){this.#J.delete(J);return}this.#J.set(J,Q),this.#z(J,Q)}setSlotHtml(J,Q){let X=Q?.trim()??"";if(X.length===0){this.setSlotContent(J,null);return}let Z=this.#U(J);if(Z!=null&&Z.innerHTML===X){this.#J.set(J,Z),this.#z(J,Z);return}let Y=document.createElement("div");Y.innerHTML=X,this.setSlotContent(J,Y)}#U(J){let Q=this.#J.get(J)??null;if(Q!=null)return Q;let X=this.#X;if(X==null)return null;for(let Z of Array.from(X.children)){if(!(Z instanceof HTMLElement))continue;if(Z.dataset.fileTreeManagedSlot===J)return Z}return null}#z(J,Q){if(Q.slot=J,Q.dataset.fileTreeManagedSlot=J,this.#X!=null&&Q.parentNode!==this.#X)this.#X.appendChild(Q)}#q(J){for(let Q of Array.from(J.children)){if(!(Q instanceof HTMLElement))continue;let X=Q.dataset.fileTreeManagedSlot;if(X==null||this.#J.has(X))continue;this.#J.set(X,Q)}}};var Z9=0;function DX(J){if(J!=null&&J.length>0)return J;return Z9+=1,`pst_ft_${Z9}`}function TX({initialVisibleRowCount:J,itemHeight:Q}){return J==null?e3:Math.max(0,J)*(Q??t3)}function Y9(J){if(typeof document>"u")return;let Q=document.createElement("div");Q.innerHTML=J;let X=Q.querySelector("svg");return X instanceof SVGElement?X:void 0}function W9(J){return J.querySelector("#file-tree-icon-chevron")instanceof SVGElement&&J.querySelector("#file-tree-icon-file")instanceof SVGElement&&J.querySelector("#file-tree-icon-dot")instanceof SVGElement&&J.querySelector("#file-tree-icon-lock")instanceof SVGElement}function q9(J){return Array.from(J.children).filter((Q)=>Q instanceof SVGElement)}var G9=class{static LoadedCustomComponent=x7;#J;#X;#U;#z;#q;#I;#u;#O;#Z;#L=new X9;#b;#B;#_;#F;#H;#k;#A;#c;#p;#f=null;#Y;#h=!1;#l=!1;constructor(J){let{composition:Q,density:X,fileTreeSearchMode:Z,gitStatus:Y,id:W,initialSearchQuery:q,icons:G,itemHeight:$,onSearchChange:A,onSelectionChange:K,overscan:M,renderRowDecoration:U,renaming:j,search:_,searchBlurBehavior:F,searchFakeFocus:k,stickyFolders:b,unsafeCSS:E,initialVisibleRowCount:L,...B}=J;this.#J=Q,this.#U=DX(W),this.#F=X5(Y),this.#H=G,this.#k=E,this.#z=K,this.#q=U,this.#I=j!=null&&j!==!1,this.#u=F,this.#O=_===!0,this.#Z=k===!0,this.#b=y7(X,$),this.#B={itemHeight:this.#b.itemHeight,overscan:M,stickyFolders:b,initialVisibleRowCount:L},this.#X=new i7({...B,fileTreeSearchMode:Z,initialSearchQuery:q,onSearchChange:A,renaming:j}),this.#p=this.#X.getSelectionVersion(),this.#f=this.#z==null?null:this.subscribe(()=>{this.#w()})}unmount(){if(this.#Y!=null)Q9(this.#Y),delete this.#Y.dataset.fileTreeVirtualizedWrapper,this.#Y=void 0;if(this.#L.clearAll(),this.#L.setHost(null),this.#_!=null)delete this.#_.dataset.fileTreeVirtualized,this.#x(this.#_),this.#_=void 0}cleanUp(){this.unmount(),this.#f?.(),this.#f=null,this.#X.destroy()}getFileTreeContainer(){return this.#_}getItem(J){return this.#X.getItem(J)}getFocusedItem(){return this.#X.getFocusedItem()}getFocusedPath(){return this.#X.getFocusedPath()}getSelectedPaths(){return this.#X.getSelectedPaths()}getComposition(){return this.#J}getItemHeight(){return this.#b.itemHeight}getDensityFactor(){return this.#b.factor}subscribe(J){let Q=!1;return this.#X.subscribe(()=>{if(!Q){Q=!0;return}J()})}focusPath(J){this.#X.focusPath(J)}scrollToPath(J,Q){this.#X.scrollToPath(J,Q)}focusNearestPath(J){return this.#X.focusNearestPath(J)}add(J){this.#X.add(J)}batch(J){this.#X.batch(J)}move(J,Q,X){this.#X.move(J,Q,X)}onMutation(J,Q){return this.#X.onMutation(J,Q)}setSearch(J){this.#X.setSearch(J)}openSearch(J){this.#X.openSearch(J)}closeSearch(){this.#X.closeSearch()}isSearchOpen(){return this.#X.isSearchOpen()}getSearchValue(){return this.#X.getSearchValue()}getSearchMatchingPaths(){return this.#X.getSearchMatchingPaths()}focusNextSearchMatch(){this.#X.focusNextSearchMatch()}focusPreviousSearchMatch(){this.#X.focusPreviousSearchMatch()}startRenaming(J,Q){return this.#X.startRenaming(J,Q)}remove(J,Q){this.#X.remove(J,Q)}resetPaths(J,Q){this.#X.resetPaths(J,Q)}setComposition(J){this.#J=J;let Q=this.#G();if(Q==null)return;this.#D(),T3(Q.wrapper,this.#y())}setGitStatus(J){this.#F=X5(J,this.#F);let Q=this.#G();if(Q==null)return;T3(Q.wrapper,this.#y())}setIcons(J){this.#H=J;let Q=this.#G();if(Q==null)return;this.#j(Q.host,Q.wrapper),T3(Q.wrapper,this.#y())}hydrate({fileTreeContainer:J}){let Q=this.#v(J),X=this.#P(Q);this.#D(),J9(X,this.#y())}render({containerWrapper:J,fileTreeContainer:Q}){let X=this.#v(Q??this.#_,J),Z=this.#P(X);this.#D(),T3(Z,this.#y())}#t(){return{initialViewportHeight:TX({initialVisibleRowCount:this.#B.initialVisibleRowCount,itemHeight:this.#B.itemHeight}),itemHeight:this.#B.itemHeight,overscan:this.#B.overscan,stickyFolders:this.#B.stickyFolders}}#y(){return{composition:this.#J,controller:this.#X,gitStatusByPath:this.#F?.statusByPath,ignoredGitDirectories:this.#F?.ignoredDirectoryPaths,directoriesWithGitChanges:this.#F?.directoriesWithChanges,icons:this.#H,instanceId:this.#U,renamingEnabled:this.#I,renderRowDecoration:this.#q,searchBlurBehavior:this.#u,searchEnabled:this.#O,searchFakeFocus:this.#Z,slotHost:this.#L,...this.#t()}}#G(){let J=this.#_,Q=this.#Y;if(J==null||Q==null)return null;return{host:J,wrapper:Q}}#j(J,Q){let X=J.shadowRoot;if(X!=null)this.#d(X),this.#i(X);this.#s(Q)}#w(){let J=this.#z;if(J==null)return;let Q=this.#X.getSelectionVersion();if(Q===this.#p)return;this.#p=Q,J(this.#X.getSelectedPaths())}#D(){let J=this.#J?.header?.render;if(J!=null){this.#L.setSlotContent(H3,J());return}this.#L.setSlotHtml(H3,this.#J?.header?.html??null)}#d(J){let Q=q9(J).find((Z)=>W9(Z)),X=Y9(D7(c1(this.#H).set));if(X==null)return;if(Q!=null&&Q.outerHTML===X.outerHTML)return;if(Q!=null)Q.replaceWith(X);else J.prepend(X)}#i(J){let Q=q9(J),X=Q.find((q)=>W9(q)),Z=Q.filter((q)=>q!==X),Y=c1(this.#H).spriteSheet?.trim()??"";if(Y.length===0){for(let q of Z)q.remove();return}let W=Y9(Y);if(W==null){for(let q of Z)q.remove();return}if(Z.length===1&&Z[0].outerHTML===W.outerHTML)return;for(let q of Z)q.remove();J.appendChild(W)}#s(J){let Q=c1(this.#H);if(Q.colored&&C7(Q.set))J.dataset.fileTreeColoredIcons="true";else delete J.dataset.fileTreeColoredIcons}#$(J){let Q=J.querySelector(`style[${h4}]`);if(this.#A==null&&Q instanceof HTMLStyleElement)this.#A=Q;if(this.#k==null||this.#k===""){this.#A?.remove(),this.#A=void 0,this.#c=void 0;return}if(this.#A?.parentNode===J&&this.#c===this.#k)return;if(this.#A??=document.createElement("style"),this.#A.setAttribute(h4,""),this.#A.parentNode!==J)J.appendChild(this.#A);this.#A.textContent=S7(this.#k),this.#c=this.#k}#P(J){if(this.#Y!=null)return this.#Y;let Q=J.shadowRoot;if(Q==null)throw Error("FileTree requires a shadow root");let X=Array.from(Q.children).filter((Y)=>Y instanceof HTMLDivElement&&typeof Y.dataset.fileTreeId==="string"&&Y.dataset.fileTreeId.length>0),Z=X.find((Y)=>Y.dataset.fileTreeId===this.#U)??X[0];if(Z!=null)this.#U=Z.dataset.fileTreeId??this.#U;if(this.#Y=Z??document.createElement("div"),this.#Y.dataset.fileTreeId=this.#U,this.#Y.dataset.fileTreeVirtualizedWrapper="true",this.#j(J,this.#Y),this.#Y.parentNode!==Q)Q.appendChild(this.#Y);return this.#Y}#v(J,Q){let X=J??this.#_??document.createElement(I1);if(Q!=null&&X.parentNode!==Q)Q.appendChild(X);let Z=X.shadowRoot??X.attachShadow({mode:"open"});return X4(X,Z),this.#$(Z),X.dataset.fileTreeVirtualized="true",X.style.display="flex",this.#E(X),this.#L.setHost(X),this.#_=X,X}#E(J){if(J.style.getPropertyValue("--trees-item-height")==="")J.style.setProperty("--trees-item-height",`${String(this.#b.itemHeight)}px`),this.#h=!0;if(J.style.getPropertyValue("--trees-density-override")==="")J.style.setProperty("--trees-density-override",String(this.#b.factor)),this.#l=!0}#x(J){if(this.#h)J.style.removeProperty("--trees-item-height"),this.#h=!1;if(this.#l)J.style.removeProperty("--trees-density-override"),this.#l=!1}};export{k7 as preparePresortedFileTreeInput,G9 as FileTree};
